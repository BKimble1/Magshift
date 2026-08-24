import Foundation

/// Where the app is, on one of the two screens that drive hardware the
/// Simulator does not have.
///
/// Named for what the user was doing, not for the type involved, because the
/// name is shown to them.
enum HardwarePhase: String, Sendable, CaseIterable {
    case openingScanScreen
    case onScanScreen
    case startingCamera
    case startingMagnetometer
    case scanning
    case openingDiagnostics
    case onDiagnosticsScreen

    /// Completes the sentence "it stopped while ...".
    var activityDescription: String {
        switch self {
        case .openingScanScreen: return "opening the scan screen"
        case .onScanScreen: return "showing the scan preparation checklist"
        case .startingCamera: return "starting the camera and AR tracking"
        case .startingMagnetometer: return "starting the magnetometer"
        case .scanning: return "scanning"
        case .openingDiagnostics: return "opening sensor diagnostics"
        case .onDiagnosticsScreen: return "showing live sensor readings"
        }
    }
}

/// Keeps a note of which hardware-driven screen the app is on, so a crash there
/// is not invisible.
///
/// # Why this exists
///
/// ARKit, RealityKit and Core Motion do not exist in the Simulator, so the code
/// that drives them is the code no test in this repository can reach. When it
/// fails it fails on someone else's iPhone, as the app vanishing, and the only
/// report available is "it crashed". That is not enough to fix anything.
///
/// # Why the note spans the whole screen, not each call
///
/// It used to be written immediately before each hardware call and erased the
/// moment that call returned. Those windows were milliseconds wide, and a crash
/// that landed outside all of them -- while the screen was rendering, or while
/// samples were being processed -- left no note at all, which is exactly what
/// happened. A blank report is indistinguishable from the mechanism not working.
///
/// So the note is now entered when a screen is opened and erased when it is
/// left, and narrowed to a more specific phase while a hardware call is in
/// progress. Anything still written down at the next launch names where the app
/// was when it died.
///
/// A screen that is left normally, or backgrounded, erases its own note, so the
/// only way to leave one behind is to stop running.
///
/// # Two places, because one of them may be the thing that is broken
///
/// The note is written to a file *and* to `UserDefaults`, and either can answer
/// at the next launch. They fail differently: the file is written atomically and
/// is on disk before the next line runs, but depends on a directory being
/// creatable; `UserDefaults` needs no directory but flushes on its own schedule,
/// so a process that dies immediately after may take the value with it. Writing
/// both means a silent failure in one does not mean silence overall.
@MainActor
enum HardwarePhaseRecorder {

    /// Records that the app has reached `phase`, replacing whatever it was doing
    /// before. Safe to call repeatedly with the same phase.
    static func enter(_ phase: HardwarePhase) {
        guard phase != current else { return }
        current = phase
        write(phase)
    }

    /// Records that the app has left the hardware screens under its own power.
    static func leave() {
        current = nil
        erase()
    }

    /// Runs `work` under a more specific phase, restoring the previous one after.
    @discardableResult
    static func during<T>(_ phase: HardwarePhase, _ work: () throws -> T) rethrows -> T {
        let previous = current
        enter(phase)
        defer {
            if let previous { enter(previous) } else { leave() }
        }
        return try work()
    }

    /// The phase a previous launch did not come back from, if any. Reading it
    /// erases it, so one crash is reported once.
    static func takeUnfinishedPhase() -> HardwarePhase? {
        let fromFile = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        let fromDefaults = defaults.string(forKey: defaultsKey)
        erase()
        return (fromFile ?? fromDefaults).flatMap(HardwarePhase.init(rawValue:))
    }

    // MARK: - Storage

    /// Records a phase without entering it, so a test can leave a note the way a
    /// crash would and read it back. Production code goes through `enter`.
    static func recordUnfinished(_ phase: HardwarePhase) {
        write(phase)
    }

    static func erase() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        defaults.removeObject(forKey: defaultsKey)
    }

    private static var current: HardwarePhase?

    private static let defaultsKey = "wallfield.diagnostics.unfinishedHardwarePhase"
    private static var defaults: UserDefaults { .standard }

    private static func write(_ phase: HardwarePhase) {
        if let fileURL {
            try? Data(phase.rawValue.utf8).write(to: fileURL, options: .atomic)
        }
        defaults.set(phase.rawValue, forKey: defaultsKey)
    }

    /// Resolved once. The directory is created on first use; if that fails the
    /// file half does nothing and `UserDefaults` carries the note alone, because
    /// a diagnostic aid must never be the reason a scan cannot start.
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
