import Foundation

/// Shared number and date formatting.
///
/// Every µT value in the UI goes through `Format.microtesla` so precision is
/// consistent, and so the unit symbol is never hard-coded at a call site.
enum Format {
    static let microteslaSymbol = "\u{00B5}T"

    /// Formats a magnetic-field value, e.g. `48.7 µT`.
    static func microtesla(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return "--" }
        return String(format: "%.\(decimals)f %@", value, microteslaSymbol)
    }

    /// Formats a signed delta, e.g. `+6.2 µT` or `-3.1 µT`.
    static func signedMicrotesla(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return "--" }
        let sign = value >= 0 ? "+" : "\u{2212}"
        return String(format: "%@%.\(decimals)f %@", sign, abs(value), microteslaSymbol)
    }

    /// Formats a plain number with fixed decimals, e.g. a z-score.
    static func decimal(_ value: Double, decimals: Int = 2) -> String {
        guard value.isFinite else { return "--" }
        return String(format: "%.\(decimals)f", value)
    }

    /// Formats a sample rate, e.g. `49.6 Hz`.
    static func hertz(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "--" }
        return String(format: "%.1f Hz", value)
    }

    /// Formats a distance in metres or centimetres depending on magnitude.
    static func distance(_ metres: Double) -> String {
        guard metres.isFinite else { return "--" }
        if abs(metres) < 1 {
            return String(format: "%.0f cm", metres * 100)
        }
        return String(format: "%.2f m", metres)
    }

    /// Formats a duration as `M:SS` or `H:MM:SS`.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Formats a millisecond interval, e.g. `18 ms`.
    static func milliseconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--" }
        return String(format: "%.0f ms", seconds * 1000)
    }

    /// `nonisolated(unsafe)` is justified: `DateFormatter` is documented as safe
    /// to use concurrently once configured, these instances are configured in
    /// their initialiser and never mutated afterwards, and export generation
    /// deliberately runs off the main actor.
    nonisolated(unsafe) static let scanDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// ISO-8601 with fractional seconds, used in exports only.
    ///
    /// `nonisolated(unsafe)` is justified for the same reason as `scanDate`:
    /// configured once, never mutated, and read from background export tasks.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A filesystem-safe slug for export filenames.
    static func fileSlug(_ raw: String, fallback: String = "scan") -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(48))
        return trimmed.isEmpty ? fallback : trimmed
    }
}
