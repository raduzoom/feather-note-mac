import FeatherCore
import Foundation

/// ENML (Evernote's XHTML) to Markdown, per universal/specs/import-formats.md "Evernote". Nothing is dropped:
/// what has no Markdown form is kept as raw HTML and reported.
public enum ENMLConverter {
    /// `resources` maps an `en-media` hash (MD5, hex) to its attachment.
    public static func convert(_ enml: String, resources: [String: AttachmentFile])
        -> (markdown: String, attachments: [AttachmentFile], preserved: [PreservedContent.Kind]) {
        let source = stripProlog(enml)
        guard let root = Tree.parse(numericEntities(source)) else {
            // not well-formed: keep the whole note verbatim, so every word survives in order
            let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw, [], raw.isEmpty ? [] : [.html])
        }
        var r = Renderer(resources: resources)
        // encrypted blocks are kept byte for byte, from the source (the parser loses attribute order)
        for m in (try! NSRegularExpression(pattern: #"<en-crypt\b[^>]*>([\s\S]*?)</en-crypt>"#, options: [.caseInsensitive]))
            .matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
            let ns = source as NSString
            r.cryptBlocks[ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)] = ns.substring(with: m.range)
        }
        let blocks = r.blocks(root.children)
        let markdown = blocks.joined(separator: "\n\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
        var seen: Set<PreservedContent.Kind> = []
        // a to-do that wasn't at a line start (mid-line, in a heading) keeps its box as text
        let cleaned = markdown.replacingOccurrences(of: Renderer.todoMarker + "x", with: "[x] ")
            .replacingOccurrences(of: Renderer.todoMarker + " ", with: "[ ] ")
        return (cleaned, r.used, r.preserved.filter { seen.insert($0).inserted })
    }

    static func stripProlog(_ s: String) -> String {
        s.replacingOccurrences(of: #"<\?xml[^>]*\?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<!DOCTYPE[^>]*>"#, with: "", options: .regularExpression)
    }

    /// HTML named entities aren't defined in XML without the DTD: turn the common ones into numeric references
    /// and escape the rest, so the parser keeps them as text.
    static func numericEntities(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);")
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            if ["amp", "lt", "gt", "quot", "apos"].contains(name) {
                out += "&\(name);"
            } else if let code = entities[name] {
                out += "&#\(code);"
            } else {
                out += "&amp;\(name);"
            }
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    static let entities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165, "brvbar": 166, "sect": 167,
        "uml": 168, "copy": 169, "ordf": 170, "laquo": 171, "not": 172, "shy": 173, "reg": 174, "macr": 175,
        "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183,
        "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189, "frac34": 190,
        "iquest": 191, "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197,
        "AElig": 198, "Ccedil": 199, "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204,
        "Iacute": 205, "Icirc": 206, "Iuml": 207, "ETH": 208, "Ntilde": 209, "Ograve": 210, "Oacute": 211,
        "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215, "Oslash": 216, "Ugrave": 217, "Uacute": 218,
        "Ucirc": 219, "Uuml": 220, "Yacute": 221, "THORN": 222, "szlig": 223, "agrave": 224, "aacute": 225,
        "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231, "egrave": 232,
        "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
        "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246,
        "divide": 247, "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253,
        "thorn": 254, "yuml": 255, "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218,
        "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230,
        "permil": 8240, "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "euro": 8364, "trade": 8482,
        "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596, "minus": 8722, "le": 8804, "ge": 8805,
        "ne": 8800, "infin": 8734, "zwj": 8205, "zwnj": 8204, "thinsp": 8201, "ensp": 8194, "emsp": 8195,
    ]
}

// MARK: Tree

/// A minimal DOM: elements and text.
final class Node {
    let name: String?   // nil for text
    var attributes: [String: String]
    var children: [Node] = []
    var text: String

    init(element: String, attributes: [String: String]) {
        name = element.lowercased()
        self.attributes = attributes
        text = ""
    }

    init(text: String) {
        name = nil
        attributes = [:]
        self.text = text
    }

    var isText: Bool { name == nil }

    /// All text inside, as written.
    var textContent: String { isText ? text : children.map(\.textContent).joined() }
}

enum Tree {
    static func parse(_ xml: String) -> Node? {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { return nil }
        return root
    }

    /// Elements nested deeper than this keep only their text (attached to the deepest kept element), so
    /// pathological nesting can't overflow the stack while rendering.
    static let maxDepth = 64

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var skipped = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if stack.count >= Tree.maxDepth { skipped += 1; return }
            let node = Node(element: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if skipped > 0 { skipped -= 1; return }
            stack.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let parent = stack.last else { return }
            if let last = parent.children.last, last.isText { last.text += string } else { parent.children.append(Node(text: string)) }
        }
        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            self.parser(parser, foundCharacters: String(decoding: block, as: UTF8.self))
        }
    }
}

// MARK: Rendering

private struct Renderer {
    let resources: [String: AttachmentFile]
    var used: [AttachmentFile] = []
    /// Encrypted blocks as written in the source, by their ciphertext.
    var cryptBlocks: [String: String] = [:]
    var preserved: [PreservedContent.Kind] = []

    static let headings = ["h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6]
    static let containers: Set<String> = ["div", "section", "article", "header", "footer", "center", "figure", "main", "aside", "body", "en-note", "span-block"]
    static let verbatim: Set<String> = ["iframe", "object", "svg", "video", "audio", "embed", "form", "canvas", "map", "math"]
    static let blockNames: Set<String> = containers.union(verbatim).union(["p", "ul", "ol", "table", "pre", "hr", "en-crypt", "blockquote", "dl"])
        .union(headings.keys)
    static let todoMarker = "\u{1}TODO"

    func isBlock(_ n: Node) -> Bool { n.name.map { Self.blockNames.contains($0) } ?? false }

    /// A `div` (or `p`) holding only a `br`, or nothing visible: a blank line in Evernote.
    func isBlank(_ n: Node) -> Bool {
        n.children.allSatisfy { $0.isText ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : $0.name == "br" }
    }

    func isCodeBlock(_ n: Node) -> Bool {
        n.name == "div" && (n.attributes["style"] ?? "").replacingOccurrences(of: " ", with: "").contains("-en-codeblock:true")
    }

    /// Renders a sequence of nodes as Markdown blocks. Consecutive inline-only `div`s are the lines of one paragraph.
    mutating func blocks(_ nodes: [Node]) -> [String] {
        var out: [String] = []
        var lines: [String] = []
        var pending: [Node] = []
        func flushInline(_ me: inout Renderer) {
            guard !pending.isEmpty else { return }
            let text = me.inline(pending)
            pending = []
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(contentsOf: text.components(separatedBy: "\n")) }
        }
        func flushParagraph(_ me: inout Renderer) {
            flushInline(&me)
            guard !lines.isEmpty else { return }
            out.append(Self.joinLines(lines.map { $0.trimmingCharacters(in: .whitespaces) }))
            lines = []
        }
        for n in nodes {
            if n.name == "en-media" {   // an attachment directly in a container is its own block
                flushParagraph(&self)
                out.append(inline([n]))
                continue
            }
            guard let name = n.name, isBlock(n) else { pending.append(n); continue }
            if name == "div" || name == "p" || Self.containers.contains(name), !isCodeBlock(n) {
                if isBlank(n) { flushParagraph(&self); continue }
                if n.children.contains(where: isBlock) {
                    flushParagraph(&self)
                    out += blocks(n.children)
                    continue
                }
                flushInline(&self)
                let text = inline(n.children)
                if name == "p" {
                    flushParagraph(&self)
                    if !text.isEmpty { out.append(Self.joinLines(text.components(separatedBy: "\n"))) }
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(contentsOf: text.components(separatedBy: "\n"))
                }
                continue
            }
            flushParagraph(&self)
            if let b = block(n), !b.isEmpty { out.append(b) }
        }
        flushParagraph(&self)
        return out
    }

    /// Paragraph lines joined with hard breaks; a to-do line becomes its own list item.
    static func joinLines(_ lines: [String]) -> String {
        let lines = lines.filter { !$0.isEmpty }
        let todo = lines.contains { $0.hasPrefix(todoMarker) }
        if todo {
            return lines.map { line in
                guard line.hasPrefix(todoMarker) else { return line }
                return "- [" + String(line.dropFirst(todoMarker.count).prefix(1)) + "] " + line.dropFirst(todoMarker.count + 1).trimmingCharacters(in: .whitespaces)
            }.joined(separator: "\n")
        }
        return lines.joined(separator: "  \n")
    }

    mutating func block(_ n: Node) -> String? {
        let name = n.name ?? ""
        if let level = Self.headings[name] {
            return String(repeating: "#", count: level) + " " + inline(n.children).replacingOccurrences(of: "\n", with: " ")
        }
        if isCodeBlock(n) {
            return fence(codeText(n).trimmingCharacters(in: .newlines))
        }
        switch name {
        case "pre":
            return fence(codeText(n).trimmingCharacters(in: .newlines))
        case "hr":
            return "---"
        case "ul", "ol":
            return list(n, indent: "")
        case "blockquote":
            return blocks(n.children).joined(separator: "\n\n").components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case "table":
            preserved.append(.table)
            return table(n)
        case "en-crypt":
            return crypt(n)
        case "dl":
            return blocks(n.children).joined(separator: "\n\n")
        default:
            preserved.append(.html)
            return serialize(n)
        }
    }

    mutating func list(_ n: Node, indent: String) -> String {
        var items: [String] = []
        var number = 1
        var lastChildIndent: String?
        for child in n.children {
            if child.name == "ul" || child.name == "ol" {
                // Evernote writes a nested list directly inside the list: it belongs to the item before it
                let sub = list(child, indent: lastChildIndent ?? indent)
                if items.isEmpty { items.append(sub) } else { items[items.count - 1] += "\n" + sub }
                continue
            }
            if child.isText, child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let li: Node
            if child.name == "li" {
                li = child
            } else {   // anything else in a list is kept as an item of its own
                li = Node(element: "li", attributes: [:])
                li.children = [child]
            }
            let marker = n.name == "ol" ? "\(number). " : "- "
            number += 1
            let childIndent = indent + String(repeating: " ", count: marker.count)
            lastChildIndent = childIndent
            let content = li.children.filter { $0.name != "ul" && $0.name != "ol" }
            var text = Self.joinLines(inline(content).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            if text.hasPrefix("- [") { text = String(text.dropFirst(2)) }   // a to-do item: "- [x] " + text
            var item = indent + marker + text.replacingOccurrences(of: "\n", with: "\n" + childIndent)
            for sub in li.children where sub.name == "ul" || sub.name == "ol" {
                item += "\n" + list(sub, indent: childIndent)
            }
            items.append(item)
        }
        return items.joined(separator: "\n")
    }

    /// An encrypted block exactly as written in the source.
    mutating func crypt(_ n: Node) -> String {
        preserved.append(.encrypted)
        return cryptBlocks[n.textContent.trimmingCharacters(in: .whitespacesAndNewlines)] ?? serialize(n)
    }

    /// Code as text: `<br>` and block children are line breaks.
    func codeText(_ n: Node) -> String {
        if n.isText { return n.text }
        if n.name == "br" { return "\n" }
        let inner = n.children.map(codeText).joined()
        return ["div", "p"].contains(n.name ?? "") ? inner + (inner.hasSuffix("\n") ? "" : "\n") : inner
    }

    func fence(_ code: String) -> String {
        var ticks = "```"
        while code.contains(ticks) { ticks += "`" }
        return ticks + "\n" + code + "\n" + ticks
    }

    mutating func table(_ n: Node) -> String {
        var rows: [String] = []
        func collect(_ node: Node, _ me: inout Renderer) {
            for c in node.children {
                if c.name == "tr" {
                    var cells = ""
                    for cell in c.children where cell.name == "td" || cell.name == "th" {
                        let html = me.cellHTML(cell.children).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                        cells += "<\(cell.name!)>\(html)</\(cell.name!)>"
                    }
                    rows.append("<tr>" + cells + "</tr>")
                } else if !c.isText {
                    collect(c, &me)   // thead, tbody, tfoot
                }
            }
        }
        collect(n, &self)
        return (["<table>"] + rows + ["</table>"]).joined(separator: "\n")
    }

    /// A table cell's content as reduced HTML: text, links (with their URL), attachments and encrypted blocks.
    mutating func cellHTML(_ nodes: [Node]) -> String {
        var s = ""
        for n in nodes {
            guard let name = n.name else { s += Self.escapeHTML(n.text); continue }
            switch name {
            case "a":
                let inner = cellHTML(n.children)
                if let href = n.attributes["href"], !href.isEmpty {
                    s += "<a href=\"\(Self.escapeHTML(href).replacingOccurrences(of: "\"", with: "&quot;"))\">\(inner)</a>"
                } else {
                    s += inner
                }
            case "en-media":
                let hash = (n.attributes["hash"] ?? "").lowercased()
                if let a = resources[hash] {
                    if !used.contains(a) { used.append(a) }
                    s += "<a href=\"\(ImportBundle.tokenScheme)\(a.token)\">\(Self.escapeHTML(a.filename))</a>"
                } else {
                    preserved.append(.html)
                    s += "[missing attachment \(hash)]"
                }
            case "en-crypt": s += crypt(n)
            case "br": s += "<br>"
            default: s += cellHTML(n.children)
            }
        }
        return s
    }

    /// The node as HTML on as few lines as possible (no blank lines, so it stays one raw HTML block).
    func serialize(_ n: Node) -> String {
        if n.isText { return Self.escapeHTML(n.text) }
        let attrs = n.attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(Self.escapeHTML($0.value).replacingOccurrences(of: "\"", with: "&quot;"))\"" }.joined()
        let inner = n.children.map(serialize).joined()
        let html = "<\(n.name!)\(attrs)>\(inner)</\(n.name!)>"
        return html.replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
    }

    /// Inline content as Markdown; `\n` marks a hard line break.
    mutating func inline(_ nodes: [Node]) -> String {
        var s = ""
        for n in nodes {
            guard let name = n.name else { s += Self.escape(Self.collapse(n.text)); continue }
            switch name {
            case "b", "strong": s += wrap(inline(n.children), "**")
            case "i", "em": s += wrap(inline(n.children), "*")
            case "s", "strike", "del": s += wrap(inline(n.children), "~~")
            case "br": s += "\n"
            case "code": s += code(n.textContent)
            case "a":
                let text = inline(n.children)
                if let href = n.attributes["href"], !href.isEmpty {
                    s += "[\(text.isEmpty ? Self.escape(href) : text)](\(Self.destination(href)))"
                } else {
                    s += text
                }
            case "en-crypt":
                s += crypt(n)
            case "en-todo":
                s += Self.todoMarker + ((n.attributes["checked"] ?? "").lowercased() == "true" ? "x" : " ")
            case "en-media":
                let hash = (n.attributes["hash"] ?? "").lowercased()
                if let a = resources[hash] {
                    if !used.contains(a) { used.append(a) }
                    let label = Self.escapeLabel(a.filename)
                    let link = "[\(label)](\(ImportBundle.tokenScheme)\(a.token))"
                    s += (a.mime ?? n.attributes["type"] ?? "").hasPrefix("image/") ? "!" + link : link
                } else {
                    preserved.append(.html)
                    s += "[missing attachment \(hash)]"
                }
            case "img":
                if let src = n.attributes["src"], !src.isEmpty {
                    s += "![\(Self.escapeLabel(n.attributes["alt"] ?? ""))](\(Self.destination(src)))"
                }
            default:
                if isBlock(n) {   // a block inside inline content: keep its text on its own line
                    s += "\n" + inline(n.children) + "\n"
                } else {
                    s += inline(n.children)
                }
            }
        }
        return s
    }

    func wrap(_ inner: String, _ marker: String) -> String {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return inner }
        let lead = inner.prefix { $0 == " " }, trail = String(inner.reversed().prefix { $0 == " " })
        return lead + marker + trimmed + marker + trail
    }

    func code(_ text: String) -> String {
        var ticks = "`"
        while text.contains(ticks) { ticks += "`" }
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return ticks + pad + text + pad + ticks
    }

    /// HTML whitespace (line breaks, tabs, runs of spaces) is one space.
    static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\*_`[]<".contains(ch) { out += "\\" }
            out.append(ch)
        }
        // a "#" that would start a line starts a heading
        if out.hasPrefix("#") { out = "\\" + out }
        return out
    }

    static func escapeLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func destination(_ url: String) -> String {
        url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) ? "<" + url.replacingOccurrences(of: ">", with: "%3E") + ">" : url
    }
}
