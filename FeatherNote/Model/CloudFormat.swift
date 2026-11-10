import Foundation

/// Sizes and relative times as the Feather Cloud screens write them ("2.4 GB of 10 GB used", "2 min ago").
enum CloudFormat {
    /// Powers of 1,024; one decimal under 10 unless whole; "MB" or "GB".
    static func size(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let (value, unit) = gb >= 1 ? (gb, "GB") : (Double(bytes) / 1_048_576, "MB")
        let rounded = (value * 10).rounded() / 10
        if value >= 10 || rounded == rounded.rounded() { return "\(Int(value.rounded())) \(unit)" }
        return String(format: "%.1f %@", rounded, unit)
    }

    static func usage(used: Int64, quota: Int64) -> String { "\(size(used)) of \(size(quota)) used" }

    /// "just now", "2 min ago", "3 h ago", "yesterday", "9 Nov".
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3600)) h ago"
        case ..<172_800: return "yesterday"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d MMM"
            return f.string(from: date)
        }
    }
}
