import CryptoKit
import Darwin
import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

enum Fixture {
    static func url(_ path: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: path)
    }

    /// Scratch folders the readers made that still exist.
    static func scratchFolders() -> Set<String> {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(all.filter { $0.hasPrefix("FeatherImport-") })
    }
}

@Suite(.serialized) struct ENEXReaderTests {
    @Test func readsNotesTagsDates() throws {
        let b = try ENEXReader.read(Fixture.url("enex/basic.enex"))
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        #expect(b.notebooks == [ImportBundle.Notebook(key: "enex", name: "basic", parentKey: nil)])
        #expect(b.notes.map(\.title) == ["Kitchen renovation quotes", "Second"])
        #expect(b.notes.allSatisfy { $0.notebookKey == "enex" })
        #expect(b.notes[0].tags == ["kitchen", "q3", "a, b"])   // a tag with a comma stays one tag
        #expect(b.notes[0].created == 1_762_696_320_000)
        #expect(b.notes[0].modified == 1_762_761_600_000)
        #expect(b.notes[0].body.hasSuffix("Source: https://quotes.example/kitchen"))
    }

    @Test func resourcesDecodeAndHash() throws {
        let b = try ENEXReader.read(Fixture.url("enex/basic.enex"))
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let a = try #require(b.notes[0].attachments.first)
        #expect(a.filename == "counter.png" && a.mime == "image/png")
        let data = try Data(contentsOf: a.file)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() == "70599eb2d64a47d1ab4f2e96b0e203d6")
        #expect(b.notes[1].attachments.isEmpty)
    }

    @Test func bodyIsMarkdownWithAttachmentLinks() throws {
        let b = try ENEXReader.read(Fixture.url("enex/basic.enex"))
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        #expect(b.notes[0].body == "Three quotes so far.\n\n![counter.png](feather-import://r1)\n\nSource: https://quotes.example/kitchen")
        #expect(b.notes[1].body == "Plain & simple.")
    }

    @Test func unreferencedResourceIsNotDropped() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "FNUnref-\(UUID().uuidString).enex")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?><en-export><note><title>T</title><content><![CDATA[<en-note><div>text</div></en-note>]]></content>        <resource><data encoding="base64">AQID</data><mime>application/pdf</mime><resource-attributes><file-name>scan.pdf</file-name></resource-attributes></resource></note></en-export>
        """.utf8).write(to: url)
        let b = try ENEXReader.read(url)
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        #expect(b.notes[0].body == "text\n\n[scan.pdf](feather-import://r1)")
        #expect(b.notes[0].attachments.count == 1)
    }

    @Test func largeResourceStreamsToDisk() throws {
        // a 60 MB resource, written in chunks so the test itself doesn't hold it
        let url = FileManager.default.temporaryDirectory.appending(path: "FNBig-\(UUID().uuidString).enex")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: Data("""
        <?xml version="1.0" encoding="UTF-8"?><en-export><note><title>Big</title><content><![CDATA[<en-note><div>x</div></en-note>]]></content><resource><data encoding="base64">
        """.utf8))
        let chunk = Data(repeating: 0xAB, count: 3 * 1024 * 1024).base64EncodedData(options: .lineLength76Characters)
        for _ in 0..<20 { try h.write(contentsOf: chunk); try h.write(contentsOf: Data("\n".utf8)) }
        try h.write(contentsOf: Data("</data><mime>application/octet-stream</mime></resource></note></en-export>".utf8))
        try h.close()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = footprint()
        let b = try ENEXReader.read(url)
        let peak = peakFootprint()
        defer { b.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let size = try #require(try b.notes[0].attachments.first?.file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size == 60 * 1024 * 1024)
        #expect(peak - before < 40 * 1024 * 1024, "peak grew by \((peak - before) / 1_048_576) MB")
    }

    @Test func truncatedEnexFailsCleanly() throws {
        // its own scratch parent: other suites make scratch folders in the shared temporary folder in parallel
        let parent = FileManager.default.temporaryDirectory.appending(path: "FNScratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect {
            try ENEXReader.read(Fixture.url("enex/truncated.enex"), scratchIn: parent)
        } throws: { error in
            if case ENEXError.malformed = error { return true }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test func notENEX() {
        #expect(throws: ENEXError.notENEX) { try ENEXReader.read(Fixture.url("enex/not-enex.html")) }
    }
}

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Int(info.phys_footprint)
}

func peakFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Int(info.ledger_phys_footprint_peak)
}
