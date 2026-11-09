import FeatherCore
import Foundation
import Testing
@testable import FeatherNote

private let locale = Locale(identifier: "en_GB")
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private let now = ISO8601DateFormatter().date(from: "2026-11-09T14:00:00Z")!
private func ms(_ iso: String) -> Int64 { Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000) }

@Test func listDateCases() {
    func f(_ iso: String) -> String { Formatting.listDate(ms(iso), now: now, calendar: calendar, locale: locale) }
    #expect(f("2026-11-09T10:42:00Z") == "Today, 10:42")
    #expect(f("2026-11-08T23:59:00Z") == "Yesterday")
    #expect(f("2026-11-07T09:00:00Z") == "7 Nov")
    #expect(f("2025-11-02T09:00:00Z") == "2 Nov 2025")
}

@Test func editedLineCases() {
    func f(_ iso: String) -> String { Formatting.editedLine(ms(iso), now: now, calendar: calendar, locale: locale) }
    #expect(f("2026-11-09T10:42:00Z") == "Edited today at 10:42")
    #expect(f("2026-11-08T09:00:00Z") == "Edited yesterday at 09:00")
    #expect(f("2026-11-07T09:00:00Z") == "Edited 7 Nov")
    #expect(f("2025-11-02T09:00:00Z") == "Edited 2 Nov 2025")
}

@Test func trashMetaCountsDown() {
    func f(_ iso: String, _ days: Int = 30) -> String {
        Formatting.trashMeta(trashedAt: ms(iso), retentionDays: days, now: now, calendar: calendar, locale: locale)
    }
    #expect(f("2026-11-03T10:00:00Z") == "Deleted 3 Nov · removed in 24 days")
    #expect(f("2026-11-09T09:00:00Z") == "Deleted today · removed in 30 days")
    #expect(f("2026-10-11T10:00:00Z") == "Deleted 11 Oct · removed in 1 day")
    #expect(f("2026-10-01T10:00:00Z") == "Deleted 1 Oct · removed today")
    #expect(f("2026-11-08T13:00:00Z", 7) == "Deleted yesterday · removed in 6 days")
}

@Test func noteMetaLine() {
    let s = NoteSummary(id: ULID.generate(at: 1), title: "Weather station build", preview: "", notebookID: nil,
                        pinned: false, modified: ms("2026-11-09T10:42:00Z"), trashedAt: nil)
    #expect(Formatting.noteMeta(summary: s, notebookName: "Electronics", now: now, calendar: calendar, locale: locale) == "Today, 10:42 · Electronics")
    #expect(Formatting.noteMeta(summary: s, notebookName: nil, now: now, calendar: calendar, locale: locale) == "Today, 10:42")
}

@Test func confirmationTexts() {
    let a = Formatting.deleteNotebookConfirmation(name: "Home", subNotebooks: 2, notes: 19)
    #expect(a.title == "Delete “Home”?")
    #expect(a.message == "Its 2 sub-notebooks are deleted too, and its 19 notes move to the Trash.")
    #expect(a.button == "Delete Notebook")
    #expect(Formatting.deleteNotebookConfirmation(name: "A", subNotebooks: 1, notes: 1).message == "Its 1 sub-notebook is deleted too, and its 1 note moves to the Trash.")
    #expect(Formatting.deleteNotebookConfirmation(name: "A", subNotebooks: 0, notes: 3).message == "Its 3 notes move to the Trash.")
    #expect(Formatting.deleteNotebookConfirmation(name: "A", subNotebooks: 2, notes: 0).message == "Its 2 sub-notebooks are deleted too.")
    #expect(Formatting.deleteNotebookConfirmation(name: "A", subNotebooks: 0, notes: 0).message == "It's empty.")

    let e = Formatting.emptyTrashConfirmation(count: 2)
    #expect(e.title == "Empty the Trash?" && e.message == "2 notes will be deleted for good. This can't be undone." && e.button == "Empty Trash")
    #expect(Formatting.emptyTrashConfirmation(count: 1).message == "1 note will be deleted for good. This can't be undone.")

    let d = Formatting.deletePermanentlyConfirmation(title: "Bread notes")
    #expect(d.title == "Delete “Bread notes” permanently?" && d.message == "This can't be undone." && d.button == "Delete Permanently")
    #expect(Formatting.deletePermanentlyConfirmation(title: "").title == "Delete “Untitled” permanently?")
}

@Test func accessibilityLabels() {
    var s = NoteSummary(id: ULID.generate(at: 1), title: "Groceries", preview: "", notebookID: nil,
                        pinned: true, modified: ms("2026-11-09T08:15:00Z"), trashedAt: nil)
    #expect(Formatting.rowAccessibilityLabel(summary: s, notebookName: "Personal", now: now, calendar: calendar, locale: locale)
            == "Groceries, pinned, Today, 08:15, Personal")
    s.pinned = false
    s.title = ""
    #expect(Formatting.rowAccessibilityLabel(summary: s, notebookName: nil, now: now, calendar: calendar, locale: locale)
            == "Untitled, Today, 08:15")
}
