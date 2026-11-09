import Foundation
import Testing
@testable import FeatherEditor

/// Pathological nesting (pasted junk, a stuck key) must never crash the parser: it recurses once per level.
@Suite struct NestingLimitTests {
    static let deep: [(String, String)] = [
        ("quotes", String(repeating: "> ", count: 10_000) + "x"),
        ("quotes in list items", String(repeating: "- > ", count: 5_000) + "x"),
        ("stars", String(repeating: "*", count: 10_000) + "a" + String(repeating: "*", count: 10_000)),
        ("underscores", String(repeating: "_", count: 10_000) + "a" + String(repeating: "_", count: 10_000)),
        ("separate emphasis", String(repeating: "*a ", count: 10_000) + String(repeating: "b* ", count: 10_000)),
        ("quotes with tabs", String(repeating: ">\t", count: 10_000) + "x"),
        ("list markers with tabs", String(repeating: "-\t", count: 10_000) + "x"),
        ("quotes after a hard line break", "a\\\n" + String(repeating: "> ", count: 10_000) + "x"),
        ("nested images", String(repeating: "![", count: 10_000) + "x" + String(repeating: "](u)", count: 10_000)),
    ]

    @Test(arguments: deep.map(\.0)) func deeplyNestedInputParses(_ name: String) {
        let text = Self.deep.first { $0.0 == name }!.1
        let doc = MarkdownParser.parse(text)
        #expect(!doc.blocks.isEmpty)
    }

    @Test func quoteDepthStopsAtTheLimit() {
        let doc = MarkdownParser.parse(String(repeating: "> ", count: 200) + "x")
        let depths = doc.blocks.compactMap { if case .quote(let d) = $0.kind { d } else { nil } }
        #expect(depths.max() == NestingLimit.depth)
    }

    @Test func ordinaryMarkdownIsUntouched() {
        let samples = Corpus.all().map(\.text) + [String(repeating: "word **b** _i_ [l](u) ", count: 2_000),
                                                  String(repeating: "> ", count: NestingLimit.depth) + "x\r\n\r\n" + String(repeating: "[", count: 32)]
        for text in samples {
            #expect(NestingLimit.apply(text).utf8.elementsEqual(text.utf8))
        }
    }

    @Test func limitedTextKeepsEveryOffset() {
        for (_, text) in Self.deep {
            let limited = NestingLimit.apply(text)
            #expect(limited.utf8.count == text.utf8.count && (limited as NSString).length == (text as NSString).length)
        }
    }
}
