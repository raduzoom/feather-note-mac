import AppKit

/// What a layout fragment draws for a paragraph (read from the attribute at the paragraph's start).
public enum Decoration: Hashable, Sendable {
    case bullet(depth: Int)
    case number
    case checkbox(checked: Bool)
    case quote(depth: Int, first: Bool, last: Bool)
    case code(language: String?, first: Bool, last: Bool)
    case rule
    case image(url: String, alt: String)
    case chip(url: String, name: String)
}

public extension NSAttributedString.Key {
    /// `Decoration` for the paragraph or span.
    static let featherDecoration = NSAttributedString.Key("featherDecoration")
    /// `true` on syntax characters drawn invisibly at zero width.
    static let featherHidden = NSAttributedString.Key("featherHidden")
    /// The URL of a link span (⌘-click opens it). Not `.link`, which would make every click follow it.
    static let featherLink = NSAttributedString.Key("featherLink")
    /// The `feather://attachment/…` URL of an attachment chip's text.
    static let featherChip = NSAttributedString.Key("featherChip")
}
