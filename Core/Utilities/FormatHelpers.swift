import Foundation

/// Display formatting: byte counts, dates and durations.
/// All formatters are created on demand (they are not thread-safe to share).
public enum FormatHelpers {
    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func byteCount(_ bytes: Int) -> String {
        byteCount(Int64(bytes))
    }

    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public static func dateAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Relative description, e.g. "in 12 days" / "3 days ago".
    public static func relativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// `mm:ss` or `h:mm:ss` for durations.
    public static func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Transfer speed, e.g. "1.2 MB/s".
    public static func transferSpeed(bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return byteCount(Int64(bytesPerSecond)) + "/s"
    }

    /// Percentage with no decimal places, clamped to 0...100.
    public static func percent(_ value: Double) -> String {
        let clamped = min(1.0, max(0.0, value))
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Short fingerprint: first 8 + last 8 hex chars, e.g. "AB12CD34…EF567890".
    public static func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 20 else { return fingerprint }
        let prefix = fingerprint.prefix(8)
        let suffix = fingerprint.suffix(8)
        return "\(prefix)…\(suffix)"
    }
}
