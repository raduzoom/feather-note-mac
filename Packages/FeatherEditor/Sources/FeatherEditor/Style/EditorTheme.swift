import AppKit

/// Fonts, colours and metrics from universal/design/tokens.json and markdown-rendering.md.
public struct EditorTheme: @unchecked Sendable {
    public var body, h1, h2, h3, h4: NSFont
    public var mono13, monoCode, monoRaw, quote, hidden: NSFont
    public var textBody, textPrimary, textSecondary, textPlaceholder, accent, accentFill, marker: NSColor
    public var inlineCodeBackground, quoteBackground, codeBackground, codeText, hairline, unrenderedBackground: NSColor
    public var syntaxKeyword, syntaxString, syntaxComment: NSColor

    public var measure: CGFloat = 560
    public var bodyLineHeight: CGFloat = 25.6
    public var lineHeights: [Int: CGFloat] = [1: 36, 2: 28.6, 3: 23.4]
    public var codeLineHeight: CGFloat = 20
    public var quoteLineHeight: CGFloat = 27.2
    public var rawLineHeight: CGFloat = 21.6
    public var listIndent: CGFloat = 24
    public var quoteIndent: CGFloat = 16
    public var codePadding: CGFloat = 16
    public var blankLineHeight: CGFloat = 16
    public var ruleLineHeight: CGFloat = 49

    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        d = d.withDesign(.serif) ?? d
        if italic { d = d.withSymbolicTraits(.italic) }
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> NSColor {
        func c(_ v: UInt32, _ a: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark, da) : c(light, la) }
    }

    public static let standard: EditorTheme = {
        EditorTheme(
            body: serif(16), h1: serif(30, .bold), h2: serif(22, .bold), h3: serif(18, .bold), h4: serif(16, .bold),
            mono13: .monospacedSystemFont(ofSize: 13, weight: .regular),
            monoCode: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
            monoRaw: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
            quote: serif(17, italic: true),
            hidden: .systemFont(ofSize: 0.01),
            textBody: dynamic(0x1C2B3E, 0xDDE6E1), textPrimary: dynamic(0x13243A, 0xECF2EE),
            textSecondary: dynamic(0x3E4C5A, 0xA4B1BC), textPlaceholder: dynamic(0x6E7B88, 0x8C99A4),
            accent: dynamic(0x1F7A55, 0x6FD3A3), accentFill: dynamic(0x1F7A55, 0x4FBF8A), marker: dynamic(0x3F6F57, 0x8CCBAA),
            inlineCodeBackground: dynamic(0x1F7A55, 0x6FD3A3, 0.10, 0.14), quoteBackground: dynamic(0xFFFFFF, 0xFFFFFF, 0.55, 0.06),
            codeBackground: dynamic(0x16263B, 0x060E14, 1, 0.70), codeText: dynamic(0xE3EEE8, 0xE3EEE8),
            hairline: dynamic(0x13243A, 0xFFFFFF, 0.16, 0.16), unrenderedBackground: dynamic(0x13243A, 0xFFFFFF, 0.04, 0.04),
            syntaxKeyword: dynamic(0xF2B880, 0xF2B880), syntaxString: dynamic(0x8FDAB4, 0x8FDAB4), syntaxComment: dynamic(0x9FB2C4, 0x9FB2C4))
    }()

    func headingFont(_ level: Int) -> NSFont {
        switch level { case 1: h1; case 2: h2; case 3: h3; default: h4 }
    }
}
