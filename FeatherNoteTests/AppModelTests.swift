import FeatherCore
import Foundation
import Synchronization
import Testing
@testable import FeatherNote

final class MovableClock: Sendable {
    let value: Atomic<Int64>
    init(_ start: Int64) { value = Atomic(start) }
    var library: LibraryClock { LibraryClock { self.value.load(ordering: .relaxed) } }
    func advance(_ ms: Int64) { value.add(ms, ordering: .relaxed) }
}

@MainActor
func makeModel(clock: LibraryClock = .system, defaults: UserDefaults? = nil) async throws -> AppModel {
    let dir = FileManager.default.temporaryDirectory.appending(path: "FNModel-\(UUID().uuidString)")
    let model = try AppModel.open(at: dir, clock: clock, defaults: defaults ?? UserDefaults(suiteName: "FNTests-\(UUID().uuidString)")!)
    await model.load()
    return model
}

private let day: Int64 = 86_400_000

@MainActor @Suite struct AppModelTests {
    @Test func firstLaunchShowsFirstLaunchState() async throws {
        let m = try await makeModel()
        #expect(m.emptyState == .firstLaunch)
        #expect(m.selection == .all && m.notes.isEmpty && m.editor == nil)
    }

    @Test func emptyStateForEachSituation() async throws {
        let m = try await makeModel()
        await m.newNote()
        await m.selectNote(nil)
        #expect(m.emptyState == .noNoteSelected)
        let nb = try #require(await m.createNotebook(name: "Projects", parent: nil))
        await m.select(.notebook(nb.id))
        #expect(m.emptyState == .emptyView)
        await m.select(.trash)
        #expect(m.emptyState == .emptyTrash)
        await m.select(.all)
        await m.setSearch("zzz")
        #expect(m.emptyState == .noSearchResults(query: "zzz", limitedTo: nil))
        await m.setSearch("")
        await m.select(.notebook(nb.id))
        await m.setSearch("zzz")
        #expect(m.emptyState == .noSearchResults(query: "zzz", limitedTo: "Projects"))
    }

    @Test func newNoteGoesToSelectedNotebook() async throws {
        let m = try await makeModel()
        let nb = try #require(await m.createNotebook(name: "Projects", parent: nil))
        await m.select(.notebook(nb.id))
        await m.newNote()
        let e = try #require(m.editor)
        #expect(e.notebookID == nb.id && m.selectedNoteID == e.id && m.notes.map(\.id) == [e.id])
    }

    @Test func newNoteInTagViewGetsThatTag() async throws {
        let m = try await makeModel()
        let tag = try #require(await m.createTag(name: "ideas"))
        await m.select(.tag(tag.id))
        await m.newNote()
        #expect(m.editor?.tagIDs == [tag.id] && m.notes.count == 1)
    }

    @Test func newNoteFromTrashGoesToAllNotes() async throws {
        let m = try await makeModel()
        await m.select(.trash)
        await m.newNote()
        #expect(m.selection == .all && m.notes.count == 1 && m.editor != nil)
    }

    @Test func editsSaveAfterDebounce() async throws {
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editBody("hello")
        m.editTitle("Hi")
        #expect(try await m.library.note(id)?.body == "")
        try await Task.sleep(for: .milliseconds(800))
        let saved = try await m.library.note(id)
        #expect(saved?.body == "hello" && saved?.title == "Hi")
        #expect(m.notes.first?.title == "Hi")
    }

    @Test func switchingNotesFlushesPendingEdit() async throws {
        let m = try await makeModel()
        await m.newNote()
        let first = try #require(m.selectedNoteID)
        await m.newNote()
        let second = try #require(m.selectedNoteID)
        await m.selectNote(first)
        m.editBody("typed fast")
        await m.selectNote(second)
        #expect(try await m.library.note(first)?.body == "typed fast")
        m.editBody("then switched view")
        await m.select(.trash)
        #expect(try await m.library.note(second)?.body == "then switched view")
    }

    @Test func titleEditKeepsExactBytes() async throws {
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editTitle("Caf\u{E9}")
        await m.flush()
        m.editTitle("Cafe\u{301}")   // canonically equal, different bytes
        await m.flush()
        #expect(try await m.library.note(id).map { Array($0.title.utf8) } == Array("Cafe\u{301}".utf8))
    }

    @Test func flushBeforeQuitSaves() async throws {
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editBody("last words")
        await m.flush()
        #expect(try await m.library.note(id)?.body == "last words")
    }

    @Test func trashingSelectedNoteSelectsNeighbour() async throws {
        let clock = MovableClock(1_762_696_320_000)
        let m = try await makeModel(clock: clock.library)
        var ids: [ULID] = []
        for _ in 0..<3 { await m.newNote(); ids.append(m.selectedNoteID!); clock.advance(1000) }
        // newest first: [c, b, a]
        let (a, b, c) = (ids[0], ids[1], ids[2])
        #expect(m.notes.map(\.id) == [c, b, a])
        await m.selectNote(b)
        await m.trash(b)
        #expect(m.selectedNoteID == a)
        await m.trash(a)
        #expect(m.selectedNoteID == c)
        await m.trash(c)
        #expect(m.selectedNoteID == nil && m.editor == nil)
    }

    @Test func movingOutOfViewedNotebookSelectsNeighbour() async throws {
        let m = try await makeModel()
        let nb = try #require(await m.createNotebook(name: "A", parent: nil))
        await m.select(.notebook(nb.id))
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        await m.move(id, to: nil)
        #expect(m.selectedNoteID == nil && m.editor == nil && m.notes.isEmpty)
        #expect(try await m.library.note(id)?.notebookID == nil)
    }

    @Test func trashedNoteIsReadOnly() async throws {
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editBody("kept")
        await m.flush()
        await m.trash(id)
        await m.select(.trash)
        await m.selectNote(id)
        #expect(m.editor?.isTrashed == true)
        m.editBody("changed")
        m.editTitle("changed")
        await m.flush()
        #expect(m.editor?.body == "kept")
        #expect(try await m.library.note(id)?.body == "kept")
        await m.restore(id)
        #expect(m.selection == .trash && m.notes.isEmpty)
    }

    @Test func staleSearchResultsAreDropped() async throws {
        let m = try await makeModel()
        await m.newNote(); m.editBody("alpha"); await m.flush()
        await m.newNote(); m.editBody("abacus"); await m.flush()
        m.searchDelay = { $0 == "a" ? .milliseconds(300) : .zero }
        async let slow: Void = m.setSearch("a")
        try await Task.sleep(for: .milliseconds(50))
        await m.setSearch("ab")
        await slow
        #expect(m.searchText == "ab")
        #expect(m.searchHits?.count == 1)
    }

    @Test func searchStartsLimitedToSelectedNotebook() async throws {
        let m = try await makeModel()
        let nb = try #require(await m.createNotebook(name: "Projects", parent: nil))
        await m.newNote(); m.editBody("sensor root"); await m.flush()
        await m.select(.notebook(nb.id))
        await m.newNote(); m.editBody("sensor inside"); await m.flush()
        await m.setSearch("sensor")
        #expect(m.searchNotebookID == nb.id && m.searchHits?.count == 1)
        await m.setSearchNotebook(nil)
        #expect(m.searchHits?.count == 2)
        let tag = try #require(await m.createTag(name: "hw"))
        await m.toggleSearchTag(tag.id)
        #expect(m.searchHits?.isEmpty == true)
        await m.setSearch("")
        #expect(m.searchHits == nil && m.searchTagIDs.isEmpty && m.searchNotebookID == nil)
    }

    @Test func countsRefreshAfterActions() async throws {
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        #expect(m.counts.all == 1)
        await m.togglePin(id)
        #expect(m.counts.pinned == 1 && m.editor?.pinned == true)
        await m.trash(id)
        #expect(m.counts.all == 0 && m.counts.trash == 1)
        await m.emptyTrash()
        #expect(m.counts.trash == 0)
    }

    @Test func deleteNotebookMovesNotesToTrashAndSelectsAll() async throws {
        let m = try await makeModel()
        let nb = try #require(await m.createNotebook(name: "Home", parent: nil))
        let sub = try #require(await m.createNotebook(name: "Sub", parent: nb.id))
        await m.select(.notebook(sub.id))
        await m.newNote()
        #expect(m.subNotebookCount(of: nb.id) == 1)
        await m.deleteNotebook(nb.id)
        #expect(m.selection == .all && m.notebooks.isEmpty && m.counts.trash == 1)
    }

    @Test func duplicateTagShowsError() async throws {
        let m = try await makeModel()
        _ = await m.createTag(name: "Travel")
        #expect(await m.createTag(name: "travel") == nil)
        #expect(m.lastError == "A tag named “travel” already exists.")
    }

    @Test func cycleMoveShowsError() async throws {
        let m = try await makeModel()
        let a = try #require(await m.createNotebook(name: "A", parent: nil))
        let b = try #require(await m.createNotebook(name: "B", parent: a.id))
        await m.moveNotebook(a.id, to: b.id)
        #expect(m.lastError == "A notebook can't go inside its own sub-notebook.")
    }

    @Test func retentionSettingPurges() async throws {
        let clock = MovableClock(1_762_696_320_000)
        let defaults = UserDefaults(suiteName: "FNTests-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "FNModel-\(UUID().uuidString)")
        do {
            let m = try AppModel.open(at: dir, clock: clock.library, defaults: defaults)
            await m.load()
            m.trashRetentionDays = 7
            await m.newNote()
            await m.trash(m.selectedNoteID!)
            #expect(m.counts.trash == 1)
        }
        clock.advance(8 * day)
        let again = try AppModel.open(at: dir, clock: clock.library, defaults: defaults)
        #expect(again.trashRetentionDays == 7)
        await again.load()
        #expect(again.counts.trash == 0)
    }
}

@MainActor @Test func onlyANewNoteAsksForTitleFocus() async throws {
    let m = try await makeModel()
    await m.newNote()
    #expect(m.titleWantsFocus)
    m.titleTookFocus()
    let id = try #require(m.selectedNoteID)
    await m.selectNote(nil)
    await m.selectNote(id)
    #expect(!m.titleWantsFocus)
}

// MARK: Final review regressions (C1, C2, I1, I3, I4)

@MainActor @Suite struct ReviewRegressionTests {
    func noteWith(_ m: AppModel, body: String) async throws -> ULID {
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editBody(body)
        await m.flush()
        return id
    }

    @Test func searchFilteringOutDirtyNoteKeepsEdit() async throws {
        let m = try await makeModel()
        let a = try await noteWith(m, body: "alpha")
        _ = try await noteWith(m, body: "beta")
        await m.selectNote(a)
        m.editBody("alpha typed")
        await m.setSearch("beta")
        await m.flush()
        #expect(try await m.library.note(a)?.body == "alpha typed")
    }

    @Test func clearingSearchInPinnedViewKeepsEdit() async throws {
        let m = try await makeModel()
        let a = try await noteWith(m, body: "alpha")
        await m.select(.pinned)
        await m.setSearch("alpha")
        await m.selectNote(a)
        m.editBody("alpha more")
        await m.setSearch("")
        await m.flush()
        #expect(try await m.library.note(a)?.body == "alpha more")
    }

    @Test func inFlightSearchDoesNotStealNewNote() async throws {
        let m = try await makeModel()
        _ = try await noteWith(m, body: "xylophone")
        m.searchDelay = { $0 == "x" ? .milliseconds(300) : .zero }
        async let slow: Void = m.setSearch("x")
        try await Task.sleep(for: .milliseconds(50))
        await m.newNote()
        let fresh = try #require(m.selectedNoteID)
        m.editTitle("Fresh")
        await slow
        #expect(m.selectedNoteID == fresh && m.editor?.title == "Fresh")
        await m.flush()
        #expect(try await m.library.note(fresh)?.title == "Fresh")
    }

    @Test func inFlightSearchDoesNotSurviveViewSwitch() async throws {
        let m = try await makeModel()
        _ = try await noteWith(m, body: "xylophone")
        m.searchDelay = { $0 == "x" ? .milliseconds(300) : .zero }
        async let slow: Void = m.setSearch("x")
        try await Task.sleep(for: .milliseconds(50))
        await m.select(.recent)
        await slow
        #expect(m.searchText == "" && m.searchHits == nil)
    }

    @Test func editDuringReloadIsKept() async throws {
        let m = try await makeModel()
        _ = try await noteWith(m, body: "start")
        let tag = try #require(await m.createTag(name: "t"))
        for k in 0..<40 {
            let rename = Task { await m.renameTag(tag.id, to: "t\(k)") }
            for _ in 0..<k { await Task.yield() }
            m.editBody("v\(k)")
            await rename.value
            #expect(m.editor?.body == "v\(k)", "yield \(k)")
        }
        await m.flush()
        #expect(try await m.library.note(m.selectedNoteID!)?.body == "v39")
    }

    @Test func searchInTrashFindsTrashedNotes() async throws {
        let m = try await makeModel()
        let a = try await noteWith(m, body: "lost recipe")
        _ = try await noteWith(m, body: "live recipe")
        await m.trash(a)
        await m.select(.trash)
        await m.setSearch("recipe")
        #expect(m.searchHits?.map(\.note.id) == [a])
    }

    @Test func searchInTagViewStartsFilteredToTheTag() async throws {
        let m = try await makeModel()
        let tag = try #require(await m.createTag(name: "hw"))
        await m.select(.tag(tag.id))
        await m.newNote(); m.editBody("sensor tagged"); await m.flush()
        await m.select(.all)
        await m.newNote(); m.editBody("sensor plain"); await m.flush()
        await m.select(.tag(tag.id))
        await m.setSearch("sensor")
        #expect(m.searchTagIDs == [tag.id] && m.searchHits?.count == 1)
    }

    @Test func tagMenuStateIsRightForNotesThatAreNotOpen() async throws {
        let m = try await makeModel()
        let tag = try #require(await m.createTag(name: "hw"))
        let a = try await noteWith(m, body: "a")
        _ = try await noteWith(m, body: "b")   // b is open now
        await m.toggleTag(tag.id, on: a)
        #expect(m.tagsByNote[a] == [tag.id])
        await m.toggleTag(tag.id, on: a)
        #expect(m.tagsByNote[a, default: []].isEmpty)
        #expect(try await m.library.note(a)?.tagIDs == [])
    }
}
