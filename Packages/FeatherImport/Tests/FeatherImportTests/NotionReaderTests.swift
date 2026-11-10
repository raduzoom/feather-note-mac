import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

/// Builds Notion-style exports at test time and zips them with ditto.
enum NotionFixture {
    static let home = "0123456789abcdef0123456789abcdef"
    static let projects = "11111111111111111111111111111111"
    static let shed = "22222222222222222222222222222222"
    static let tasks = "33333333333333333333333333333333"
    static let paint = "44444444444444444444444444444444"
    static let roof = "55555555555555555555555555555555"
    static let ideasA = "66666666666666666666666666666666"
    static let ideasB = "77777777777777777777777777777777"

    static func folder(_ files: [String: Data]) -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "FNNotion-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (path, data) in files {
            let url = root.appending(path: path)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! data.write(to: url)
        }
        return root
    }

    static func zip(_ folder: URL) -> URL {
        let zip = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", folder.path, zip.path]
        try! p.run()
        p.waitUntilExit()
        return zip
    }

    static func t(_ s: String) -> Data { Data(s.utf8) }

    static func standard() -> URL {
        zip(folder([
            "Home \(home).md": t("# Home\n\nWelcome. See [Projects](Home%20\(home)/Projects%20\(projects).md).\n\n![](Home%20\(home)/photo%201.png)\n\n```\n![](Home%20\(home)/photo%201.png)\n```\n"),
            "Home \(home)/photo 1.png": Data([0x89, 0x50, 0x4E, 0x47, 1, 2]),
            "Home \(home)/Projects \(projects).md": t("# Projects\n\n<aside>💡 Remember the permit</aside>\n\n<details><summary>Toggle</summary>Hidden text</details>\n"),
            "Home \(home)/Projects \(projects)/Shed \(shed).md": t("# Shed\n\nBuild it.\n"),
            "Home \(home)/Tasks \(tasks).csv": t("Name,Status,Tags,Due,Notes\nPaint,Doing,\"home, outdoor\",\"November 10, 2026\",Two coats\nFix roof,Doing,home,,\"Call \"\"Bob\"\", maybe\"\n"),
            "Home \(home)/Tasks \(tasks)/Paint \(paint).md": t("# Paint\n\nStatus: Doing\n\nTags: home, outdoor\n\nDue: November 10, 2026\n\nNotes: Two coats\n\nBuy brushes.\n"),
            "Home \(home)/Tasks \(tasks)/Fix roof \(roof).md": t("# Fix roof\n\nStatus: Doing\n\nTags: home\n\nNotes: Call \"Bob\", maybe\n"),
            "Ideas \(ideasA).md": t("# Ideas\n\nFirst list.\n"),
            "Ideas \(ideasB).md": t("# Ideas\n\nSecond list.\n"),
            "Hash 0123abcd.md": t("# Hash 0123abcd\n\nNot an id.\n"),
        ]))
    }
}

@Suite struct NotionReaderTests {
    func read() throws -> ImportBundle { try NotionReader.read(NotionFixture.standard()) }

    func notebook(_ b: ImportBundle, _ name: String) -> ImportBundle.Notebook? { b.notebooks.first { $0.name == name } }
    func notes(_ b: ImportBundle, titled title: String) -> [ImportBundle.Note] { b.notes.filter { $0.title == title } }

    @Test func pageTreeBecomesNotebooks() throws {
        let b = try read()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let notion = try #require(notebook(b, "Notion"))
        #expect(notion.parentKey == nil)
        let home = try #require(notebook(b, "Home"))
        let projects = try #require(notebook(b, "Projects"))
        #expect(home.parentKey == notion.key && projects.parentKey == home.key)
        #expect(notes(b, titled: "Home").first?.notebookKey == home.key)
        #expect(notes(b, titled: "Projects").first?.notebookKey == projects.key)
        #expect(notes(b, titled: "Shed").first?.notebookKey == projects.key)
        #expect(notes(b, titled: "Shed").first?.body == "Build it.")
        #expect(b.notebooks.filter { $0.parentKey == nil }.count == 1)
    }

    @Test func databaseRowsBecomeNotes() throws {
        let b = try read()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let tasks = try #require(notebook(b, "Tasks"))
        let paint = try #require(notes(b, titled: "Paint").first)
        #expect(paint.notebookKey == tasks.key)
        #expect(Set(paint.tags) == ["Doing", "home", "outdoor"])
        #expect(paint.body == "- **Due:** November 10, 2026\n- **Notes:** Two coats\n\nBuy brushes.")
        let roof = try #require(notes(b, titled: "Fix roof").first)
        #expect(Set(roof.tags) == ["Doing", "home"])
        #expect(roof.body == "- **Notes:** Call \"Bob\", maybe")
    }

    @Test func imagesAndFilesBecomeAttachments() throws {
        let b = try read()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let home = try #require(notes(b, titled: "Home").first)
        let a = try #require(home.attachments.first)
        #expect(a.filename == "photo 1.png")
        #expect(home.body.contains("![](feather-import://\(a.token))"))
        #expect(home.body.contains("[Projects](Home%20\(NotionFixture.home)/Projects%20\(NotionFixture.projects).md)"))   // page links kept
        #expect(home.body.contains("```\n![](Home%20\(NotionFixture.home)/photo%201.png)\n```"))   // code untouched
        #expect(home.attachments.count == 1)
    }

    @Test func calloutsAndTogglesKept() throws {
        let b = try read()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let p = try #require(notes(b, titled: "Projects").first)
        #expect(p.body.contains("<aside>💡 Remember the permit</aside>") && p.body.contains("Hidden text"))
        #expect(p.preserved == [.notionBlock])
    }

    @Test func duplicatePageNamesStayDistinct() throws {
        let b = try read()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        #expect(Set(notes(b, titled: "Ideas").map(\.body)) == ["First list.", "Second list."])
    }

    @Test func idSuffixStrippedOnlyWhenNotionId() {
        #expect(NameRules.stripNotionID("Hash 0123abcd").name == "Hash 0123abcd")
        #expect(NameRules.stripNotionID("Plan 0123456789abcdef0123456789abcdef") == ("Plan", "0123456789abcdef0123456789abcdef"))
        #expect(NameRules.stripNotionID("Plan 0123456789ABCDEF0123456789abcdef").name == "Plan 0123456789ABCDEF0123456789abcdef")
    }

    @Test func notANotionExport() {
        let zip = NotionFixture.zip(NotionFixture.folder(["a.txt": NotionFixture.t("x"), "b/c.txt": NotionFixture.t("y")]))
        #expect(throws: NotionError.notANotionExport) { try NotionReader.read(zip) }
    }

    @Test func csvQuotingRoundTrips() throws {
        let t = try CSVTable("h1,h2,h3\r\n\"a \"\"b\"\"\",\"c,d\",\"line\nbreak\"\n")
        #expect(t.header == ["h1", "h2", "h3"])
        #expect(t.rows == [["a \"b\"", "c,d", "line\nbreak"]])
        #expect(try CSVTable("\u{FEFF}Name\nx").header == ["Name"])
    }

    @Test func multiPartZip() throws {
        let part1 = NotionFixture.zip(NotionFixture.folder(["One \(NotionFixture.home).md": NotionFixture.t("# One\n\nfirst")]))
        let part2 = NotionFixture.zip(NotionFixture.folder(["Two \(NotionFixture.shed).md": NotionFixture.t("# Two\n\nsecond")]))
        let outer = NotionFixture.folder(["Part-1.zip": try Data(contentsOf: part1), "Part-2.zip": try Data(contentsOf: part2)])
        let b = try NotionReader.read(NotionFixture.zip(outer))
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        #expect(Set(b.notes.map(\.title)) == ["One", "Two"])
    }
}
