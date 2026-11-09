import Foundation

/// Language-agnostic colouring for code blocks: strings, comments and a fixed keyword list.
public enum CodeHighlighter {
    public enum Kind: Equatable, Sendable { case keyword, string, comment }
    public struct Token: Equatable, Sendable { public var range: NSRange; public var kind: Kind }

    static let hashCommentLanguages: Set<String> = ["python", "py", "ruby", "rb", "shell", "sh", "bash", "zsh", "yaml", "yml", "toml"]
    static let keywords: Set<String> = [
        "let", "var", "func", "fn", "def", "class", "struct", "enum", "protocol", "interface", "import", "from", "return",
        "if", "else", "elif", "for", "while", "in", "switch", "case", "break", "continue", "true", "false", "nil", "null",
        "None", "True", "False", "const", "public", "private", "static", "async", "await", "try", "catch", "throw", "new", "self", "this",
    ]

    public static func tokens(in code: String, language: String?) -> [Token] {
        let s = code as NSString
        var out: [Token] = []
        let hashComments = language.map { hashCommentLanguages.contains($0.lowercased()) } ?? false
        var i = 0
        func isWord(_ c: unichar) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        while i < s.length {
            let c = s.character(at: i)
            if c == 0x2F, i + 1 < s.length, s.character(at: i + 1) == 0x2F {
                let end = lineEnd(s, i); out.append(Token(range: NSRange(location: i, length: end - i), kind: .comment)); i = end; continue
            }
            if c == 0x23, hashComments {
                let end = lineEnd(s, i); out.append(Token(range: NSRange(location: i, length: end - i), kind: .comment)); i = end; continue
            }
            if c == 0x2F, i + 1 < s.length, s.character(at: i + 1) == 0x2A {
                let close = s.range(of: "*/", options: [], range: NSRange(location: i + 2, length: s.length - i - 2))
                let end = close.location == NSNotFound ? s.length : NSMaxRange(close)
                out.append(Token(range: NSRange(location: i, length: end - i), kind: .comment)); i = end; continue
            }
            if c == 0x22 || c == 0x27 || c == 0x60 {
                var j = i + 1
                while j < s.length, s.character(at: j) != c, s.character(at: j) != 0x0A {
                    if s.character(at: j) == 0x5C { j += 1 }
                    j += 1
                }
                let end = min(s.length, j + 1)
                out.append(Token(range: NSRange(location: i, length: end - i), kind: .string)); i = end; continue
            }
            if isWord(c) {
                var j = i
                while j < s.length, isWord(s.character(at: j)) { j += 1 }
                if keywords.contains(s.substring(with: NSRange(location: i, length: j - i))) {
                    out.append(Token(range: NSRange(location: i, length: j - i), kind: .keyword))
                }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    static func lineEnd(_ s: NSString, _ i: Int) -> Int {
        var j = i
        while j < s.length, s.character(at: j) != 0x0A, s.character(at: j) != 0x0D { j += 1 }
        return j
    }
}
