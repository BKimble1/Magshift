import Foundation
import os

/// Namespaced loggers.
///
/// Logging is deliberately restrained and privacy-safe: no measurement values,
/// file paths, scan names or user notes are ever logged. Only lifecycle
/// transitions and error conditions are recorded, so a sysdiagnose taken from a
/// user's device cannot leak the contents of their scans.
enum Log {
    private static let subsystem = "com.idlery.wallfield"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let sensors = Logger(subsystem: subsystem, category: "sensors")
    static let ar = Logger(subsystem: subsystem, category: "ar")
    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
