import Foundation

/// A step that drives hardware the Simulator does not have.
///
/// Named for what the user was doing, not for the class involved, because the
/// name is shown to them.
enum HardwarePhase: String, Sendable, CaseIterable {
    case preparingScan
    case preparingDiagnostics
    case startingCamera
    case startingMagnetometer

    /// Completes the sentence "it stopped while ...".
    var activityDescription: String {
        switch self {
        case .preparingScan: return "preparing a scan"
        case .preparingDiagnostics: return "opening sensor diagnostics"
        case .startingCamera: return "starting the camera and AR tracking"
        case .startingMagnetometer: return "starting the magnetometer"
        }
    }
}

/// Writes down what the app is about to ask the hardware for, and erases it the
/// moment the request returns.
///
/// # Why this exists
///
/// ARKit, RealityKit and Core Motion do not exist in the Simulator, so the code
/// that drives them is the code no test in this repository can reach. When it
/// fails it fails on someone else's iPhone, as the app vanishing, and the only
/// report available is "it crashed". That is not enough to fix anything.
///
/// So the app leaves a note before each of those steps and tears it up as soon
/// as the step returns. A note still on disk at the next launch names a step the
/// app did not come back from, and Home says so in plain words.
///
/// # Why it is trustworthy
///
/// The gap between writing the note and erasing it is one synchronous call, so
/// the only way to leave a false trail is to be terminated inside that gap. A
/// `defer` erases it on a thrown error as well as a normal return; nothing
/// erases it on a crash, which is the entire point.
///
/// The note is a four-byte file written atomically rather than a `UserDefaults`
/// key, because `UserDefaults` flushes on its own schedule and a process that
/// dies milliseconds later may take the value with it.
@MainActor
enum HardwarePhaseRecorder {

    /// Runs `work`, having first recorded that it was about to be attempted.
    @discardableResult
    static func attempting<T>(_ phase: HardwarePhase, _ work: () throws -> T) rethrows -> T {
        write(phase)
        defer { erase() }
        return try work()
    }

    /// The phase a previous launch did not return from, if any. Reading it
    /// erases it, so one crash is reported once.
    static func takeUnfinishedPhase() -> HardwarePhase? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        erase()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return HardwarePhase(rawValue: raw)
    }

    static func erase() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Storage

    /// Records a phase without running anything.
    ///
    /// Production code always goes through `attempting`. This exists because the
    /// mechanism's whole value rests on the note surviving to the next launch,
    /// and the only way to prove that in a test is to leave one deliberately --
    /// a real crash cannot be staged.
    static func recordUnfinished(_ phase: HardwarePhase) {
        write(phase)
    }

    private static func write(_ phase: HardwarePhase) {
        guard let fileURL else { return }
        try? Data(phase.rawValue.utf8).write(to: fileURL, options: .atomic)
    }

    /// Resolved once. The directory is created on first use; if that fails the
    /// recorder does nothing at all, because a diagnostic aid must never be the
    /// reason a scan cannot start.
    private static let fileURL: URL? = {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = support.appendingPathComponent("WallFieldDiagnostics", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("unfinished-hardware-phase", isDirectory: false)
    }()
}
