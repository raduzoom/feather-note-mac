import AppKit
import Testing
@testable import FeatherEditor

/// Phase 4 deferred minors (Phase 5 Task 6).
@MainActor @Suite struct ImageCacheTests {
    func load(_ cache: ImageCache, _ url: URL) async {
        var done = false
        cache.load(url) { done = true }
        _ = await waitFor({ done }, timeout: 15)
    }

    @Test func cacheEvictsLeastRecentlyUsed() async {
        let cache = ImageCache(limit: 2)
        let a = makePNG(width: 8, height: 8), b = makePNG(width: 9, height: 9), c = makePNG(width: 10, height: 10)
        await load(cache, a)
        await load(cache, b)
        _ = cache.image(for: a)   // a is used again, so b is now the oldest
        await load(cache, c)
        #expect(cache.image(for: a) != nil)
        #expect(cache.image(for: b) == nil)
        #expect(cache.image(for: c) != nil)
    }

    @Test func failedFileRetriesAfterForget() async throws {
        let cache = ImageCache()
        let url = FileManager.default.temporaryDirectory.appending(path: "FN-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        await load(cache, url)
        #expect(cache.hasFailed(url))
        try Data(contentsOf: makePNG(width: 4, height: 4)).write(to: url)
        cache.forgetFailure(for: url)
        await load(cache, url)
        #expect(cache.image(for: url) != nil)
    }

    @Test func imageLoadRestylesOnlyItsBlock() async {
        let png = makePNG(width: 400, height: 200)
        let text = String(repeating: "Paragraph with some words in it.\n\n", count: 300) + "![p](feather://attachment/IMG)\n"
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 800, height: 600))
        tv.resolveAttachment = { $0 == "feather://attachment/IMG" ? png : nil }
        tv.load(text)
        _ = await waitFor({ tv.isFullyStyled }, timeout: 15)
        tv.restyledCharacters = 0
        _ = await waitFor({ tv.imageCache.image(for: png) != nil && tv.restyledCharacters > 0 }, timeout: 15)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(tv.restyledCharacters > 0 && tv.restyledCharacters < 2_000, "restyled \(tv.restyledCharacters)")
    }

    @Test func pastedImageTempFilesAreRemoved() async throws {
        let tv = makeView("")
        var pasted: URL?
        var existedDuringImport = false
        tv.importFiles = { urls in
            pasted = urls.first
            existedDuringImport = urls.first.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return []
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("FNPaste-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(try Data(contentsOf: makePNG(width: 4, height: 4)), forType: .png)
        _ = tv.readSelection(from: pb, type: .png)
        _ = await waitFor({ pasted != nil }, timeout: 15)
        let file = try #require(pasted)
        #expect(existedDuringImport)   // the import can still read it
        #expect(await waitFor({ !FileManager.default.fileExists(atPath: file.path) }, timeout: 5))   // gone once it finished
    }
}
