import Testing
@testable import FeatherCore

@Test func frontMatterMatchesSpecExample() {
    let fm = FrontMatter(featherID: ULID(string: "01JC8ZV2VW3XY4ZA5BC6DE7FG8"), title: "Groceries",
                         created: 1_762_696_320_123, modified: 1_762_699_955_001, tags: ["shopping", "home"], pinned: false)
    #expect(fm.render() == """
        ---
        feather_id: 01JC8ZV2VW3XY4ZA5BC6DE7FG8
        title: Groceries
        created: 2025-11-09T13:52:00.123Z
        modified: 2025-11-09T14:52:35.001Z
        tags: [shopping, home]
        pinned: false
        ---


        """)
}

@Test func frontMatterQuoting() {
    #expect(FrontMatter.scalar("Groceries") == "Groceries")
    #expect(FrontMatter.scalar("Ideas: big and small") == "\"Ideas: big and small\"")
    for s in ["yes", "No", "- item", "a: b", "", "12", "1.5", "~", "null", "#tag", "x #y", " pad", "pad ", "@me", "`x`", "'q'", "\"q\"", "ends:"] {
        #expect(FrontMatter.scalar(s).hasPrefix("\""), "\(s) should be quoted")
    }
    #expect(FrontMatter.scalar("say \"hi\"\\") == "say \"hi\"\\")
    #expect(FrontMatter.scalar("\"hi\"") == "\"\\\"hi\\\"\"")
    #expect(FrontMatter.scalar("a\nb") == "\"a\\nb\"")
    #expect(FrontMatter.tagItem("a, b") == "\"a, b\"")
    #expect(FrontMatter.tagItem("[x]") == "\"[x]\"")
    #expect(FrontMatter.tagItem("plain") == "plain")
}

@Test func emptyTagsRenderAsEmptyList() {
    let fm = FrontMatter(featherID: nil, title: "x", created: 0, modified: 0, tags: [], pinned: true)
    #expect(fm.render().contains("tags: []\npinned: true\n"))
    #expect(fm.render().contains("created: 1970-01-01T00:00:00.000Z"))
}

@Test func frontMatterParses() {
    let text = "---\nfeather_id: 01JC8ZV2VW3XY4ZA5BC6DE7FG8\ntitle: \"Say \\\"hi\\\"\"\ncreated: 2025-11-09T13:52:00.123Z\nmodified: 2025-11-09T14:52:35.001Z\ntags: [shopping, \"a, b\"]\npinned: true\n---\n\nBody\n"
    let p = FrontMatter.parse(text)
    #expect(p.frontMatter == FrontMatter(featherID: ULID(string: "01JC8ZV2VW3XY4ZA5BC6DE7FG8"), title: "Say \"hi\"",
                                         created: 1_762_696_320_123, modified: 1_762_699_955_001, tags: ["shopping", "a, b"], pinned: true))
    #expect(p.body == "Body\n" && !p.keepBlock)
}

@Test func frontMatterBlockListsAndCRLF() {
    let p = FrontMatter.parse("---\r\ntitle: 'It''s'\r\ntags:\r\n  - one\r\n  - two\r\n---\r\nBody\r\n")
    #expect(p.frontMatter?.title == "It's" && p.frontMatter?.tags == ["one", "two"])
    #expect(p.body == "Body\r\n" && !p.keepBlock)
}

@Test func renderedFrontMatterParsesBack() {
    for title in ["Groceries", "yes", "a: b", "", "say \"hi\"", "x\ny", "- item", "12", "#tag", "Café ☕"] {
        let fm = FrontMatter(featherID: ULID.generate(at: 1), title: title, created: 1, modified: 2, tags: ["a, b", "[x]", "c"], pinned: false)
        let p = FrontMatter.parse(fm.render() + "body")
        #expect(p.frontMatter == fm, "\(title)")
        #expect(p.body == "body" && !p.keepBlock)
    }
}

@Test func noFrontMatter() {
    for text in ["Body", "", "--- not a block", "---\ntitle: x\nno closing line\n", "\n---\ntitle: x\n---\n"] {
        let p = FrontMatter.parse(text)
        #expect(p.frontMatter == nil && p.body == text && !p.keepBlock, "\(text)")
    }
}

@Test func unknownKeysKeepTheBlock() {
    let text = "---\naliases: [x]\ntitle: T\n---\nBody"
    let p = FrontMatter.parse(text)
    #expect(p.frontMatter?.title == "T" && p.keepBlock && p.body == text)
    #expect(FrontMatter.parse("---\npinned: maybe\n---\nB").keepBlock)
    #expect(FrontMatter.parse("---\n# comment\ntitle: T\n---\nB").keepBlock)
    #expect(FrontMatter.parse("---\ncreated: 2024-03-01\n---\nB").frontMatter?.created == 1_709_251_200_000)
}
