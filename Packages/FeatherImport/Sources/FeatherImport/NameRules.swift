import Foundation

enum NameRules {
    /// Notion adds " <32 lowercase hex digits>" to every name; strip it only when it's exactly that.
    static func stripNotionID(_ name: String) -> (name: String, id: String?) {
        guard let r = name.range(of: #" [0-9a-f]{32}$"#, options: .regularExpression) else { return (name, nil) }
        return (String(name[..<r.lowerBound]), String(name[r].dropFirst()))
    }
}
