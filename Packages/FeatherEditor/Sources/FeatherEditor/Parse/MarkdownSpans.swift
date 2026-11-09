import Foundation

/// The parsed shape of a note, as ranges into its text (UTF-16, like NSString).
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [Block]
    public init(blocks: [Block]) { self.blocks = blocks }
}

public struct Block: Equatable, Sendable {
    public var kind: BlockKind
    public var range: NSRange
    public var inlines: [Inline]
    /// Syntax the editor hides or reveals for this block: "# ", fence lines, "> ", list markers.
    public var markers: [NSRange]
}

public enum Checkbox: Equatable, Sendable {
    /// Range of the "[ ]" / "[x]" text.
    case unchecked(NSRange), checked(NSRange)
}

public enum BlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case listItem(ordered: Bool, depth: Int, checkbox: Checkbox?)
    case quote(depth: Int)
    case codeBlock(language: String?, contentRange: NSRange)
    case thematicBreak
    /// A paragraph that is exactly one image.
    case image(alt: String, url: String, sourceRange: NSRange)
    /// Tables, HTML blocks and anything else shown as plain source.
    case unrendered
}

public struct Inline: Equatable, Sendable {
    public var kind: InlineKind
    public var range: NSRange
    public var markers: [NSRange]
}

public enum InlineKind: Hashable, Sendable {
    case strong, emphasis, strikethrough, code
    case link(url: String)
    case html
}
