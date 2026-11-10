import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

/// Fixes found by importing real sample exports from current Evernote and Notion (2026-11).
@Suite struct SampleExportFixTests {
    let pdf = AttachmentFile(token: "r1", file: URL(fileURLWithPath: "/tmp/r1"), filename: "quote.pdf", mime: "application/pdf")
    let png = AttachmentFile(token: "r2", file: URL(fileURLWithPath: "/tmp/r2"), filename: "tile.png", mime: "image/png")

    func md(_ inner: String) -> String {
        ENMLConverter.convert("<en-note>\(inner)</en-note>", resources: ["aa": pdf, "bb": png]).markdown
    }

    // Current Evernote writes checklists as a styled list, not as en-todo
    @Test func styledChecklistBecomesTasks() {
        let enml = #"<ul style="--en-todo:true;"><li style="--en-checked:false;"><div>Call the plumber</div></li><li style="--en-checked:true;"><div>Pick tiles</div></li></ul>"#
        #expect(md(enml) == "- [ ] Call the plumber\n- [x] Pick tiles")
    }

    @Test func styledChecklistNestedUnderBullet() {
        let enml = #"<ul><li><div>Kitchen</div></li><ul style="--en-todo: true;"><li style="--en-checked: true;"><div>Order</div></li></ul></ul>"#
        #expect(md(enml) == "- Kitchen\n  - [x] Order")
    }

    @Test func ordinaryListStaysBullets() {
        #expect(md(#"<ul style="--en-todo:false;"><li><div>a</div></li></ul>"#) == "- a")
    }

    // Evernote shows a PDF inline with a style attribute; it must still be a link
    @Test func styledPDFMediaIsLinked() {
        let enml = #"<div>See</div><en-media style="--en-viewAs:pdf-pageByPage;" hash="aa" type="application/pdf" /><en-media hash="bb" type="image/png" style="--en-naturalWidth:256;" />"#
        #expect(md(enml) == "See\n\n[quote.pdf](feather-import://r1)\n\n![tile.png](feather-import://r2)")
    }

    // Current Notion exports name sub-page and database folders without the id
    static let page = "41422b7f7f438039900fcb34a4ff8999"
    static let db = "41422b7f7f4380c2b1adcc996b3f933f"
    static let tomato = "41422b7f7f43807882d5ee9ef87eda2e"
    static let basil = "41422b7f7f4380d2b30af600a17b37fd"
    static let child = "41422b7f7f4380d2b30af600a17b3700"

    func readIdlessFolders() throws -> ImportBundle {
        let t = NotionFixture.t
        return try NotionReader.read(NotionFixture.zip(NotionFixture.folder([
            "Garden \(Self.page).md": t("# Garden\n\nPlan.\n\n[Plants](Garden/Plants%20\(Self.db).csv)\n"),
            "Garden/Plants \(Self.db).csv": t("\u{FEFF}Name,Tags\r\nTomato,summer\r\nBasil,\"herb, summer\""),
            "Garden/Plants \(Self.db)_all.csv": t("\u{FEFF}Name,Tags\r\nTomato,summer\r\nBasil,\"herb, summer\""),
            "Garden/Plants/Tomato \(Self.tomato).md": t("# Tomato\n\nTags: summer\n\nStake them.\n"),
            "Garden/Plants/Basil \(Self.basil).md": t("# Basil\n\nTags: herb, summer\n"),
            "Garden/Shed \(Self.child).md": t("# Shed\n\nPaint it.\n"),
        ])))
    }

    @Test func idlessPageFolderBecomesNotebook() throws {
        let b = try readIdlessFolders()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let notion = try #require(b.notebooks.first { $0.name == "Notion" })
        let garden = try #require(b.notebooks.first { $0.name == "Garden" })
        #expect(garden.parentKey == notion.key)
        #expect(b.notes.first { $0.title == "Garden" }?.notebookKey == garden.key)
        #expect(b.notes.first { $0.title == "Shed" }?.notebookKey == garden.key)
        #expect(b.notebooks.first { $0.name == "Plants" }?.parentKey == garden.key)
    }

    @Test func idlessDatabaseFolderGivesOneNotePerRow() throws {
        let b = try readIdlessFolders()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let tomatoes = b.notes.filter { $0.title == "Tomato" }
        let basils = b.notes.filter { $0.title == "Basil" }
        #expect(tomatoes.count == 1 && basils.count == 1)
        #expect(tomatoes.first?.tags == ["summer"] && tomatoes.first?.body == "Stake them.")
        #expect(Set(basils.first?.tags ?? []) == ["herb", "summer"] && basils.first?.body == "")
    }

    @Test func databaseLinkKeptAsWritten() throws {
        let b = try readIdlessFolders()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let garden = try #require(b.notes.first { $0.title == "Garden" })
        #expect(garden.attachments.isEmpty)
        #expect(garden.body == "Plan.\n\n[Plants](Garden/Plants%20\(Self.db).csv)")
    }

    // A CSV the user attached to a page (no Notion id) is still an attachment
    @Test func attachedCSVStaysAttachment() throws {
        let t = NotionFixture.t
        let b = try NotionReader.read(NotionFixture.zip(NotionFixture.folder([
            "Budget \(Self.page).md": t("# Budget\n\n[costs.csv](Budget/costs.csv)\n"),
            "Budget/costs.csv": t("a,b\n1,2\n"),
        ])))
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let note = try #require(b.notes.first { $0.title == "Budget" })
        #expect(note.attachments.map(\.filename) == ["costs.csv"])
    }
}
