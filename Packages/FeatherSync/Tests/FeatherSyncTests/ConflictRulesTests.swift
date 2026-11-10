import FeatherCore
import Foundation
import Testing
@testable import FeatherSync

@Suite struct ConflictRulesTests {
    let t0: Int64 = 1_762_696_320_123
    func note(_ title: String = "Groceries", body: String = "milk", tags: Set<ULID> = [], pinned: Bool = false) -> Note {
        Note(id: ULID(string: "01JC8ZQ6V4N1XG2H3K5M7P9R0T")!, title: title, body: body, notebookID: nil, tagIDs: tags, pinned: pinned,
             created: t0, modified: t0, trashedAt: nil)
    }

    @Test func textDiffersMakesACopy() {
        #expect(ConflictRules.resolveNote(local: note(body: "eggs"), server: note(), localDeleted: false, serverDeleted: false) == .copyLocal)
        #expect(ConflictRules.resolveNote(local: note("Shopping"), server: note(), localDeleted: false, serverDeleted: false) == .copyLocal)
    }

    @Test func onlyMetadataDiffersMerges() {
        let a = ULID(string: "01JC8ZR1AB2CD3EF4GH5JK6MN7")!, b = ULID(string: "01JC8ZS4QW8XY2Z3A4B5C6D7E8")!
        let local = note(tags: [a], pinned: false)
        var server = note(tags: [b], pinned: true)
        server.trashedAt = t0 + 1
        guard case .mergeMeta(let merged) = ConflictRules.resolveNote(local: local, server: server, localDeleted: false, serverDeleted: false) else {
            Issue.record("expected merge"); return
        }
        #expect(merged.tagIDs == [a, b] && merged.pinned && merged.trashedAt == t0 + 1 && merged.body == "milk")
    }

    @Test func localEditAgainstTombstoneRepushes() {
        #expect(ConflictRules.resolveNote(local: note(body: "edit"), server: note(), localDeleted: false, serverDeleted: true) == .repushLocal)
    }

    @Test func localDeleteAgainstServerEditKeepsServer() {
        #expect(ConflictRules.resolveNote(local: note(), server: note(body: "edit"), localDeleted: true, serverDeleted: false) == .keepServer)
    }

    @Test func conflictTitleFormat() {
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Europe/Bucharest")!
        cal.timeZone = tz
        let at = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 32))!
        #expect(ConflictRules.conflictTitle("Groceries", device: "MacBook Air", at: at, calendar: cal, timeZone: tz)
                == "Groceries (conflict, MacBook Air, 9 Nov 14:32)")
        let empty = ConflictRules.conflictTitle("", device: "Mac", at: at, calendar: cal, timeZone: tz)
        #expect(empty == " (conflict, Mac, 9 Nov 14:32)" && empty != "")
    }

    @Test func namesServerWins() {
        #expect(ConflictRules.resolveName(localName: "Trips", serverName: "Travel") == .serverWins(lost: "Trips"))
        #expect(ConflictRules.resolveName(localName: "Travel", serverName: "Travel") == .serverWins(lost: nil))
    }

    @Test func parentCycleGoesToTop() {
        let a = ULID(string: "01JC8ZR1AB2CD3EF4GH5JK6MN7")!, b = ULID(string: "01JC8ZS4QW8XY2Z3A4B5C6D7E8")!
        // locally A is inside B; the server puts B inside A: applying it to B would make a cycle
        #expect(ConflictRules.resolveParent(serverParent: a, notebookID: b, parents: [a: b, b: nil]) == nil)
        #expect(ConflictRules.resolveParent(serverParent: a, notebookID: b, parents: [a: nil, b: nil]) == a)
        #expect(ConflictRules.resolveParent(serverParent: nil, notebookID: b, parents: [a: b]) == nil)
    }
}
