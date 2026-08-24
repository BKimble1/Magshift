import Foundation
import os

/// Namespaced loggers.
///
/// Logging is deliberately restrained and privacy-safe: no measurement values,
/// file paths, scan names or user notes are ever logged. Only lifecycle
/// transitions and error conditions are recorded, so a sysdiagnose taken from a
/// user's device cannot leak the contents of their scans.
enum Log {
    /// Matches the bundle identifier, which is the convention `os_log`
    /// filtering and Console.app expect.
    private static let subsystem = "com.idlery.magshift"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let sensors = Logger(subsystem: subsystem, category: "sensors")
    static let ar = Logger(subsystem: subsystem, category: "ar")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
