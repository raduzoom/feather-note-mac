import AppKit
import Foundation
import Testing
import FeatherCore
@testable import FeatherNote

@MainActor @Suite struct CaptureIntegrationTests {
    func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("FNService-\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        return pb
    }

    @Test func serviceTextBecomesNote() async throws {
        let m = try await makeModel()
        let p = try #require(await m.createNotebook(name: "Personal", parent: nil))
        m.quickNoteNotebookID = p.id
        let provider = ServicesProvider(model: m)
        #expect(await provider.save(from: pasteboard { $0.setString("Idea\nmore", forType: .string) }))
        let notes = try await m.library.notes(in: .notebook(p.id))
        #expect(notes.map(\.title) == ["Idea"])
    }

    @Test func serviceURLBecomesURLNote() async throws {
        let m = try await makeModel()
        let provider = ServicesProvider(model: m)
        #expect(await provider.save(from: pasteboard { $0.setString("https://a.example/p", forType: .string) }))
        let summary = try #require(try await m.library.notes(in: .all).first)
        let note = try #require(try await m.library.note(summary.id))
        #expect(note.title == "a.example")
        #expect(note.body.hasPrefix("<https://a.example/p>"))
    }

    @Test func emptyServicePasteboardSavesNothing() async throws {
        let m = try await makeModel()
        #expect(!(await ServicesProvider(model: m).save(from: pasteboard { _ in })))
        #expect(m.noteCount == 0)
    }

    @Test func drainOnActivation() async throws {
        let m = try await makeModel()
        try m.inbox.write(InboxItem(id: ULID.generate(at: 1_762_696_320_000), kind: .text, text: "From the share sheet",
                                    created: 1_762_696_320_000), files: [])
        #expect(await m.drainInbox() == 1)
        #expect(m.notes.map(\.title).contains("From the share sheet"))
        #expect(await m.drainInbox() == 0)
    }
}

/// Share extension hand-off (plan Task 4, Decision 4 fallback): one named pasteboard per capture.
@MainActor @Suite struct ShareHandOffTests {
    @Test func extensionItemReachesLibrary() async throws {
        let prefix = "FNHandOff-\(UUID().uuidString)"
        let file = FileManager.default.temporaryDirectory.appending(path: "FN-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        let item = InboxItem(id: ULID.generate(at: 1_762_696_320_000), kind: .url, url: "https://a.example/page",
                             title: "A page", created: 1_762_696_320_000)
        // the extension delivers while the app isn't looking
        _ = try InboxHandOff.deliver(item, files: [file], prefix: prefix)
        // the app opens later, receives feathermark://inbox?id=…, and collects it
        let m = try await makeModel()
        #expect(await m.collectHandOff(id: item.id, prefix: prefix) == 1)
        #expect(await m.collectHandOff(id: item.id, prefix: prefix) == 0)
        let notes = try await m.library.notes(in: .all)
        #expect(notes.map(\.title) == ["A page"])
        #expect(try await m.library.attachments().count == 1)
    }

    @Test func oversizedHandOffIsRefused() throws {
        let big = FileManager.default.temporaryDirectory.appending(path: "FN-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(InboxHandOff.maxBytes + 1))
        try h.close()
        let item = InboxItem(id: ULID.generate(at: 1), kind: .files, created: 1)
        #expect(throws: InboxHandOff.HandOffError.tooLarge) { _ = try InboxHandOff.deliver(item, files: [big], prefix: "FNHandOff-\(UUID().uuidString)") }
    }
}
