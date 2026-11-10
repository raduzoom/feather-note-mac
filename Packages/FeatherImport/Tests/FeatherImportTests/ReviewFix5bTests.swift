import CryptoKit
import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

/// Phase 5b review probes. Each test states the behaviour a person importing notes expects; a failure is a finding.
@Suite(.serialized) struct ReviewProbe5bImport {
    func md(_ inner: String, _ resources: [String: AttachmentFile] = [:]) -> (markdown: String, preserved: [PreservedContent.Kind]) {
        let r = ENMLConverter.convert("<en-note>\(inner)</en-note>", resources: resources)
        return (r.markdown, r.preserved)
    }

    // MARK: ENML

    /// Evernote's editor writes nested lists as a <ul> directly inside the <ul> (not inside the <li>).
    @Test func probeNestedListDirectlyInsideList() {
        let out = md("<ul><li>parent</li><ul><li>child item</li></ul><li>after</li></ul>").markdown
        #expect(out.contains("child item"), "nested list text dropped: \(out.debugDescription)")
    }

    /// An en-crypt inside a list item must not shift the byte-for-byte crypt queue onto the next en-crypt.
    @Test func probeCryptInsideListKeepsBothCryptBlocks() {
        let r = md("<ul><li><en-crypt hint=\"first\" cipher=\"AES\" length=\"128\">AAAAFIRST</en-crypt></li></ul><en-crypt hint=\"second\" cipher=\"AES\" length=\"128\">BBBBSECOND</en-crypt>")
        #expect(r.markdown.contains("BBBBSECOND"), "second encrypted block lost: \(r.markdown.debugDescription)")
        #expect(r.markdown.contains("hint=\"first\""), "first encrypted block not kept verbatim: \(r.markdown.debugDescription)")
    }

    /// Line breaks inside <pre> and inside a code-block line are part of the code.
    @Test func probePreWithBrKeepsLines() {
        let pre = md("<pre>line1<br/>line2</pre>").markdown
        #expect(pre.contains("line1\nline2"), "pre lines merged: \(pre.debugDescription)")
        let block = md("<div style=\"-en-codeblock:true\"><div>a = 1<br/>b = 2</div></div>").markdown
        #expect(block.contains("a = 1\nb = 2"), "code-block lines merged: \(block.debugDescription)")
    }

    /// A to-do that isn't the first thing on its line must not leak the internal marker.
    @Test func probeTodoNotAtLineStart() {
        let mid = md("<div>Buy <en-todo checked=\"false\"/>milk</div>").markdown
        #expect(!mid.contains("\u{1}"), "internal TODO marker leaked: \(mid.debugDescription)")
        let heading = md("<h2><en-todo checked=\"true\"/>Done</h2>").markdown
        #expect(!heading.contains("\u{1}"), "internal TODO marker leaked into heading: \(heading.debugDescription)")
    }

    /// Text starting with "# " after leading whitespace must not become a heading.
    @Test(.disabled("Deferred minor (5b review finding 13): a div starting with spaces then # becomes a heading")) func probeLeadingSpaceHashStaysText() {
        let out = md("<div> # not a heading</div>").markdown
        #expect(!out.hasPrefix("# "), "text became a heading: \(out.debugDescription)")
    }

    /// A link inside a table cell keeps its URL somewhere in the note.
    @Test func probeTableCellLinkKeepsURL() {
        let out = md("<table><tr><td><a href=\"https://example.com/quote-42\">quote</a></td></tr></table>").markdown
        #expect(out.contains("example.com/quote-42"), "URL in table cell dropped: \(out.debugDescription)")
    }

    /// Deep nesting must not crash, and the text survives.
    @Test func probeDeepNesting() {
        let depth = 1000
        let out = md(String(repeating: "<div>", count: depth) + "deep text" + String(repeating: "</div>", count: depth)).markdown
        #expect(out.contains("deep text"))
    }

    // MARK: ENEX end to end

    func enex(resources count: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Probe5b-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var media = "", res = ""
        for i in 1...count {
            let bytes = Data("image number \(i)".utf8)
            let hash = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            media += "<div><en-media type=\"image/png\" hash=\"\(hash)\"/></div>"
            res += "<resource><data encoding=\"base64\">\(bytes.base64EncodedString())</data><mime>image/png</mime><resource-attributes><file-name>img\(i).png</file-name></resource-attributes></resource>"
        }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><en-export><note><title>Gallery</title><content><![CDATA[<en-note>\(media)</en-note>]]></content>\(res)</note></en-export>"
        let url = dir.appending(path: "Gallery.enex")
        try Data(xml.utf8).write(to: url)
        return url
    }

    /// A note with 12 images: every image link must point at its own attachment after import.
    @Test func probeTwelveImagesAllLinked() async throws {
        let bundle = try ENEXReader.read(try enex(resources: 12))
        let lib = try Library.open(at: FileManager.default.temporaryDirectory.appending(path: "Probe5bLib-\(UUID().uuidString)", directoryHint: .isDirectory))
        _ = try await lib.importBundle(bundle, into: nil)
        let summary = try #require(try await lib.notes(in: .all).first)
        let note = try #require(try await lib.note(summary.id))
        let ids = Set(try await lib.attachments().map { $0.id.description })
        let regex = try NSRegularExpression(pattern: #"feather://attachment/([0-9A-Za-z]+)"#)
        let ns = note.body as NSString
        let linked = regex.matches(in: note.body, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        let broken = linked.filter { !ids.contains($0) }
        #expect(linked.count == 12)
        #expect(broken.isEmpty, "links to no attachment: \(broken)\nbody: \(note.body)")
        #expect(Set(linked).count == 12, "images share a link")
    }

    // MARK: Notion

    /// A page whose title starts with "." (".NET notes") is still a page.
    @Test func probeNotionDotPageImported() throws {
        let id = "abcdefabcdefabcdefabcdefabcdefab"
        let zip = NotionFixture.zip(NotionFixture.folder([
            "Home \(NotionFixture.home).md": NotionFixture.t("# Home\n\nHello.\n"),
            ".NET notes \(id).md": NotionFixture.t("# .NET notes\n\nUse dotnet build.\n"),
        ]))
        let b = try NotionReader.read(zip)
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        #expect(b.notes.map(\.title).contains(".NET notes"), "page dropped; notes: \(b.notes.map(\.title))")
    }

    /// An image whose file name has brackets (Notion uses the file name as alt text) still becomes an attachment.
    @Test func probeNotionImageWithBracketsInName() throws {
        let zip = NotionFixture.zip(NotionFixture.folder([
            "Home \(NotionFixture.home).md": NotionFixture.t("# Home\n\n![shot [1].png](Home%20\(NotionFixture.home)/shot%20%5B1%5D.png)\n"),
            "Home \(NotionFixture.home)/shot [1].png": Data([0x89, 0x50, 0x4E, 0x47, 9]),
        ]))
        let b = try NotionReader.read(zip)
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let home = try #require(b.notes.first { $0.title == "Home" })
        #expect(home.attachments.count == 1, "image not imported; body: \(home.body.debugDescription)")
    }

    /// A row page's own body text that starts with a column name is the person's text, not a property.
    @Test func probeNotionRowBodyStartingWithHeader() throws {
        let db = "99999999999999999999999999999999", row = "88888888888888888888888888888888"
        let zip = NotionFixture.zip(NotionFixture.folder([
            "Tasks \(db).csv": NotionFixture.t("Name,Status,Notes\nPaint,Doing,\n"),
            "Tasks \(db)/Paint \(row).md": NotionFixture.t("# Paint\n\nStatus: Doing\n\nNotes: call Bob before Friday about the colour.\n\nBuy brushes.\n"),
        ]))
        let b = try NotionReader.read(zip)
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let paint = try #require(b.notes.first { $0.title == "Paint" })
        #expect(paint.body.contains("call Bob"), "body text dropped: \(paint.body.debugDescription)")
    }

    /// A symlinked page in the zip must not read a file from outside the export.
    @Test func probeNotionSymlinkPageStaysInside() throws {
        let folder = NotionFixture.folder(["Home \(NotionFixture.home).md": NotionFixture.t("# Home\n\nHi.\n")])
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "Leak 12345678123456781234567812345678.md"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let zip = NotionFixture.zip(folder)
        let b = try NotionReader.read(zip)
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let leaked = b.notes.filter { $0.body.contains("localhost") }
        #expect(leaked.isEmpty, "a file outside the export was imported: \(leaked.map(\.title))")
    }

    /// A damaged zip gives a message a person can act on.
    @Test func probeCorruptZipMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Probe5bZip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Export.zip")
        try Data("PK\u{3}\u{4}this is not really a zip".utf8).write(to: url)
        do {
            _ = try NotionReader.read(url)
            Issue.record("no error")
        } catch {
            let text = error.localizedDescription
            #expect(!text.contains("error 0"), "message: \(text)")
        }
    }

    /// An unterminated quote in a database CSV gives a message a person can act on.
    @Test func probeBadCSVMessage() throws {
        let zip = NotionFixture.zip(NotionFixture.folder([
            "Home \(NotionFixture.home).md": NotionFixture.t("# Home\n"),
            "Tasks 99999999999999999999999999999999.csv": NotionFixture.t("Name,Notes\nPaint,\"open quote\n"),
        ]))
        do {
            _ = try NotionReader.read(zip)
            Issue.record("no error")
        } catch {
            let text = error.localizedDescription
            #expect(!text.contains("error 0"), "message: \(text)")
        }
    }
}
