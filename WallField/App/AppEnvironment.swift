import Foundation
import Observation
import SwiftUI

/// The composition root.
///
/// Everything that has a lifetime longer than one screen is created here, once,
/// and handed down through the SwiftUI environment. There are no global mutable
/// singletons in this app: a preview, a UI test and the shipping app differ only
/// in which `AppEnvironment` they are given.
@MainActor
@Observable
final class AppEnvironment {

    let runtimeMode: RuntimeMode

    /// What this device and this install can do.
    ///
    /// Not a `let`: camera authorization is a decision the user makes, and they
    /// can make it -- or reverse it in Settings -- long after launch. Reading it
    /// once and keeping it meant granting access on the first-run screen had no
    /// effect until the app was relaunched, because everything downstream still
    /// saw `notDetermined`.
    private(set) var capabilities: DeviceCapabilities

    /// True when `capabilities` was read from this device rather than injected by
    /// a test or a preview, which is the only case where refreshing them is right.
    private let capabilitiesAreLive: Bool

    let preferences: AppPreferences
    let scanStore: any ScanStoring
    let feedback = FeedbackController()

    /// The synthetic world, present only when running on simulated data.
    let simulatedEnvironment: SimulatedEnvironment?

    /// Shared, observable view of everything on disk. Home and History read the
    /// same instance so a deletion in one is reflected in the other without a
    /// notification or a manual refresh.
    let library: ScanLibrary

    /// Set when on-disk storage could not be opened and an in-memory store is
    /// standing in. Surfaced in Settings so the user is never silently saving
    /// scans that will not survive relaunch.
    private(set) var storageFailure: String?

    // MARK: - Init

    init(
        runtimeMode: RuntimeMode = RuntimeMode.current,
        capabilities: DeviceCapabilities? = nil,
        preferences: AppPreferences? = nil,
        scanStore: (any ScanStoring)? = nil
    ) {
        self.runtimeMode = runtimeMode
        // Only capabilities this environment read for itself may be re-read
        // later. An injected set belongs to a test or a preview, and refreshing
        // it would replace the thing the test is holding fixed.
        let injectedCapabilities = capabilities
        var resolvedCapabilities = injectedCapabilities
            ?? (runtimeMode.isSimulated ? .simulated() : .current())
        if RuntimeMode.shouldSimulateCameraDenied() {
            resolvedCapabilities.cameraAuthorization = .denied
        }
        self.capabilities = resolvedCapabilities
        self.capabilitiesAreLive = injectedCapabilities == nil && !runtimeMode.isSimulated
        self.simulatedEnvironment = runtimeMode.isSimulated ? SimulatedEnvironment() : nil

        let resolvedPreferences = preferences ?? AppPreferences()
        if RuntimeMode.shouldResetPersistentState() {
            resolvedPreferences.resetAll()
        }
        self.preferences = resolvedPreferences

        let resolvedStore: any ScanStoring
        if let scanStore {
            resolvedStore = scanStore
        } else {
            do {
                resolvedStore = try FileScanStore(
                    containerDirectory: Self.storageDirectory(for: runtimeMode)
                )
            } catch {
                Log.persistence.error("Falling back to in-memory scan storage.")
                resolvedStore = InMemoryScanStore()
                self.storageFailure = """
                    \(Branding.productName) could not open its storage folder, so scans saved in this \
                    session will not be kept after you close the app.
                    """
            }
        }
        self.scanStore = resolvedStore
        self.library = ScanLibrary(store: resolvedStore)

        feedback.hapticsEnabled = self.preferences.hapticsEnabled
        feedback.soundEnabled = self.preferences.soundEnabled

        if RuntimeMode.shouldResetPersistentState() {
            Task { try? await resolvedStore.deleteAll() }
        }

        Log.app.notice("Launched in \(runtimeMode.rawValue, privacy: .public) mode.")
    }

    /// UI tests get their own container so they cannot see, or destroy, scans
    /// belonging to a real install on the same simulator.
    private static func storageDirectory(for mode: RuntimeMode) -> URL? {
        guard RuntimeMode.shouldResetPersistentState() else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("WallFieldUITests", isDirectory: true)
    }

    /// Re-reads the capabilities that can change while the app is running.
    ///
    /// Called when the app becomes active and after the first-run screen asks for
    /// camera access. Cheap enough to call on every activation: it is two
    /// framework queries and an assignment that only happens on a real change,
    /// which matters because `@Observable` invalidates observers on every write.
    func refreshCapabilities() {
        guard capabilitiesAreLive else { return }
        var refreshed = DeviceCapabilities.current()
        if RuntimeMode.shouldSimulateCameraDenied() {
            refreshed.cameraAuthorization = .denied
        }
        guard refreshed != capabilities else { return }
        capabilities = refreshed
    }

    // MARK: - Factories

    /// A fresh magnetic-field service for one scan or diagnostics session.
    ///
    /// New instances rather than a shared one: a service owns Core Motion
    /// subscriptions, and tying its lifetime to the screen that uses it is what
    /// guarantees updates stop when that screen goes away.
    func makeFieldService() -> any MagneticFieldProviding {
        if let simulatedEnvironment {
            return SimulatedMagneticFieldService(environment: simulatedEnvironment)
        }
        return CoreMotionMagneticFieldService()
    }

    /// A fresh spatial provider for one scan.
    func makeSpatialProvider() -> any ARSpatialProviding {
        if let simulatedEnvironment {
            return SimulatedSpatialProvider(environment: simulatedEnvironment)
        }
        return ARSessionController(configuration: preferences.detectorConfiguration)
    }

    func makeScanCoordinator() -> ScanCoordinator {
        ScanCoordinator(
            fieldService: makeFieldService(),
            spatialProvider: makeSpatialProvider(),
            preferences: preferences,
            scanStore: scanStore,
            feedback: feedback,
            capabilities: capabilities,
            isSimulated: runtimeMode.isSimulated,
            simulatedEnvironment: simulatedEnvironment
        )
    }

    /// Keeps the feedback controller in step with the user's preferences.
    func applyFeedbackPreferences() {
        feedback.hapticsEnabled = preferences.hapticsEnabled
        feedback.soundEnabled = preferences.soundEnabled
    }
}

extension AppEnvironment {
    /// An environment backed entirely by simulated data and in-memory storage.
    ///
    /// Used by SwiftUI previews. It touches no real sensor, no camera and no
    /// file on disk, so previews are safe to run anywhere.
    static func preview(seed: [ScanRecord] = []) -> AppEnvironment {
        AppEnvironment(
            runtimeMode: .simulated,
            capabilities: .simulated(),
            preferences: AppPreferences(
                defaults: UserDefaults(suiteName: "wallfield.previews") ?? .standard
            ),
            scanStore: InMemoryScanStore(seed: seed)
        )
    }
}
