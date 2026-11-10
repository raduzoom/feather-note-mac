import Foundation

/// A block the block menu ("+" in the margin, "/" at a line start) can insert. Every choice is plain Markdown.
public enum BlockChoice: CaseIterable, Sendable {
    case heading1, heading2, heading3, bulleted, numbered, todo, quote, divider, code, imageOrFile, scan

    public var title: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulleted: "Bulleted list"
        case .numbered: "Numbered list"
        case .todo: "To-do list"
        case .quote: "Quote"
        case .divider: "Divider"
        case .code: "Code block"
        case .imageOrFile: "Image or file"
        case .scan: "Scan from iPhone"
        }
    }

    public var symbolName: String {
        switch self {
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .bulleted: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checklist"
        case .quote: "text.quote"
        case .divider: "minus"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .imageOrFile: "photo"
        case .scan: "doc.viewfinder"
        }
    }

    /// The Markdown the choice writes, shown at the row's right.
    public var hint: String {
        switch self {
        case .heading1: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bulleted: "-"
        case .numbered: "1."
        case .todo: "[ ]"
        case .quote: ">"
        case .divider: "---"
        case .code: "```"
        case .imageOrFile, .scan: ""
        }
    }

    public var aliases: [String] {
        switch self {
        case .heading1: ["h1", "title"]
        case .heading2: ["h2"]
        case .heading3: ["h3"]
        case .bulleted: ["ul", "bullet"]
        case .numbered: ["ol", "ordered"]
        case .todo: ["todo", "task", "checkbox"]
        case .quote: ["blockquote"]
        case .divider: ["hr", "rule", "line", "separator"]
        case .code: ["pre", "snippet"]
        case .imageOrFile: ["attachment", "photo", "picture", "pdf"]
        case .scan: ["camera", "document", "ipad"]
        }
    }

    /// Headings, lists and quote: they turn a line with text into the block. The rest go below it.
    public var isTextBlock: Bool {
        switch self {
        case .heading1, .heading2, .heading3, .bulleted, .numbered, .todo, .quote: true
        default: false
        }
    }

    /// The choices whose title or alias words start with every word of `query` (case-insensitive), in menu
    /// order. An alias needs two typed characters, so "h" means the headings and not "hr".
    public static func matching(_ query: String) -> [BlockChoice] {
        guard !query.hasPrefix(" ") else { return [] }
        let words = query.lowercased().split(separator: " ").map(String.init)
        return allCases.filter { c in
            let titleWords = c.title.lowercased().split(separator: " ").map(String.init)
            return words.allSatisfy { w in
                titleWords.contains { $0.hasPrefix(w) } || (w.count >= 2 && c.aliases.contains { $0.hasPrefix(w) })
            }
        }
    }
}
