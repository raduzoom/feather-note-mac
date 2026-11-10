import AppKit
import Testing
@testable import FeatherEditor

/// Phase 5a review probes (editor). RED means a finding.
@MainActor @Suite struct ReviewProbe5aEditor {
    func onePagePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Copying a picture in Keynote, Pages, Numbers or Preview puts PDF + PNG/TIFF (no text) on the pasteboard.
    /// Pasting it should give an image, not a "Scan <date>.pdf" chip.
    @Test func probeCopiedPictureWithPDFFlavourPastesAsImage() async throws {
        let tv = makeView("")
        var received: [URL] = []
        tv.importFiles = { urls in received = urls; return [] }
        let pb = NSPasteboard(name: NSPasteboard.Name("FNProbe-\(UUID().uuidString)"))
        pb.clearContents()
        pb.declareTypes([.pdf, .png, .tiff], owner: nil)
        pb.setData(onePagePDF(), forType: .pdf)
        pb.setData(try Data(contentsOf: makePNG(width: 40, height: 40)), forType: .png)
        pb.setData(NSImage(contentsOf: makePNG(width: 40, height: 40))!.tiffRepresentation!, forType: .tiff)
        #expect(tv.readSelection(from: pb))   // what ⌘V does: the view picks the type
        _ = await waitFor({ !received.isEmpty }, timeout: 10)
        let name = received.first?.lastPathComponent ?? "(nothing imported)"
        #expect(name.hasSuffix(".png"), "imported as \(name)")
    }

    /// Continuity Camera "Take Photo" (and many apps' copied photos) offer JPEG; the view says it accepts JPEG
    /// (validRequestor), so a JPEG-only pasteboard should become an attachment.
    @Test func probeJPEGOnlyPasteboardBecomesAttachment() async throws {
        let tv = makeView("")
        #expect(tv.validRequestor(forSendType: nil, returnType: NSPasteboard.PasteboardType("public.jpeg")) as AnyObject? === tv)
        var received: [URL] = []
        tv.importFiles = { urls in received = urls; return [] }
        let rep = NSBitmapImageRep(data: NSImage(contentsOf: makePNG(width: 20, height: 20))!.tiffRepresentation!)!
        let jpeg = rep.representation(using: .jpeg, properties: [:])!
        let pb = NSPasteboard(name: NSPasteboard.Name("FNProbe-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        let accepted = tv.readSelection(from: pb)
        _ = await waitFor({ !received.isEmpty }, timeout: 5)
        #expect(accepted && received.count == 1, "readSelection returned \(accepted), imported \(received.count)")
    }

    /// A note with more images than the cache limit (64): once every image has loaded, scrolling back to the
    /// first ones must show the images, not the grey placeholder.
    @Test func probeEvictedImagesComeBack() async throws {
        let count = 70
        var files: [String: URL] = [:]
        var text = ""
        for i in 0..<count {
            let u = "feather://attachment/IMG\(i)"
            files[u] = makePNG(width: 30 + i, height: 20)
            text += "![i\(i)](\(u))\n\n"
        }
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 800, height: 600))
        tv.resolveAttachment = { files[$0] }
        tv.load(text)
        _ = await waitFor({ tv.isFullyStyled }, timeout: 20)
        let last = files["feather://attachment/IMG\(count - 1)"]!
        _ = await waitFor({ tv.imageCache.image(for: last) != nil }, timeout: 20)
        try await Task.sleep(for: .milliseconds(500))
        // scroll to the top and draw, as the person scrolling back up would
        tv.scrollToBeginningOfDocument(nil)
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))   // caret stays at the end
        tv.display()
        try await Task.sleep(for: .seconds(2))
        tv.display()
        let first = files["feather://attachment/IMG0"]!
        let missing = (0..<count).filter { tv.imageCache.image(for: files["feather://attachment/IMG\($0)"]!) == nil }
        #expect(tv.imageCache.image(for: first) != nil, "images without a thumbnail after drawing: \(missing)")
    }
}
