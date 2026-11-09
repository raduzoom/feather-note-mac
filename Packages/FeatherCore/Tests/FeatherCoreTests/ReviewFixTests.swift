import Foundation
import Testing
@testable import FeatherCore

// Regression tests for the Phase 2 final review findings.

@Test func apostropheTagsRoundTrip() {
    #expect(FrontMatter.tagItem("Mom's").hasPrefix("\""))
    #expect(FrontMatter.tagItem("say \"x\"").hasPrefix("\""))
    #expect(FrontMatter.flowList("[rock'n'roll, it's]") == ["rock'n'roll", "it's"])
    let fm = FrontMatter(title: "t", tags: ["Mom's", "don't", "it's", "say \"x\""])
    let p = FrontMatter.parse(fm.render() + "body")
    #expect(p.frontMatter?.tags == ["Mom's", "don't", "it's", "say \"x\""])
    #expect(!p.keepBlock && p.body == "body")
}

@Test func linkScannerHandlesCRLF() {
    let fenced = "```\r\n[a](in.png)\r\n```\r\n![](img.png)\r\n"
    #expect(MarkdownLinks.destinations(in: fenced).map(\.destination) == ["img.png"])
    let indented = "Intro\r\n\r\n    [x](code.png)\r\n"
    #expect(MarkdownLinks.destinations(in: indented).isEmpty)
}

@Test func exportRewritesOnlyLinkDestinations() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.addAttachment(data: Data([1]), filename: "a.png")
    let body = "```\nfeather://attachment/\(a.id)\n```\nsee feather://attachment/\(a.id) and ![](feather://attachment/\(a.id))\n"
    _ = try await lib.createNote(title: "N", body: body)
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    let text = try String(contentsOf: report.root.appending(path: "N.md"), encoding: .utf8)
    #expect(text.hasSuffix("\n---\n\n```\nfeather://attachment/\(a.id)\n```\nsee feather://attachment/\(a.id) and ![](_attachments/N/a.png)\n"))
}

@Test func markdownNamedAttachmentRoundTrips() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.addAttachment(data: Data("# hi".utf8), filename: "notes.md")
    let n = try await lib.createNote(title: "N", body: "[notes](feather://attachment/\(a.id))")
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    let copy = try TestLibrary.open()
    let imported = try await copy.importMarkdownFolder(from: report.root)
    #expect(imported.skipped.isEmpty && imported.attachments == 1 && imported.notes == 1)
    let b = try #require(try await copy.attachments().first)
    #expect(b.filename == "notes.md")
    #expect(try await copy.note(n.id)?.body == "[notes](feather://attachment/\(b.id))")
}

@Test func sanitizerReplacesForbiddenScalarsInsideClusters() {
    for name in ["a/\u{301}b", ":\u{301}", "\u{600}/x", "a\\\u{301}"] {
        let out = FileNames.sanitize(name)
        #expect(!out.unicodeScalars.contains { "/\\:*?\"<>|".unicodeScalars.contains($0) }, "\(name) -> \(out)")
    }
}

@Test func exportSurvivesCombiningMarkAfterSlash() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.createNote(title: "a/\u{301}b")
    let report = try await lib.exportMarkdown(to: TestLibrary.directory())
    #expect(report.notes == 1)
}

@Test func searchWithControlCharactersDoesNotThrow() async throws {
    let lib = try TestLibrary.open()
    let n = try await lib.createNote(title: "x", body: "alpha beta")
    #expect(try await lib.search("alpha\u{0}beta").map(\.note.id) == [n.id])
    _ = try await lib.search("\u{0}")
    _ = try await lib.search("a\u{1}\u{7F}")
}

@Test func emptyFrontMatterBlockIsKept() {
    for text in ["---\n---\nBody", "---\n\n---\nBody"] {
        let p = FrontMatter.parse(text)
        #expect(p.frontMatter == nil && p.body == text && !p.keepBlock, "\(text)")
    }
}
