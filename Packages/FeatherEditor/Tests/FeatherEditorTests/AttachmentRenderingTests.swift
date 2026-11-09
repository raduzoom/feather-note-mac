import AppKit
import Testing
@testable import FeatherEditor

func makePNG(width: Int, height: Int) -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "FNImg-\(UUID().uuidString).png")
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

/// Waits while yielding the main actor, so background loads can land.
@MainActor func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor func spacingBefore(_ tv: EditorTextView, at i: Int) -> CGFloat {
    (tv.textStorage?.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? -1
}

@MainActor @Suite struct AttachmentRenderingTests {
    let id = "01JC8ZS4QW8XY2Z3A4B5C6D7E8"

    @Test func imageReservesHeightOnceLoaded() async {
        let png = makePNG(width: 400, height: 200)
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 800, height: 600))
        tv.resolveAttachment = { $0 == "feather://attachment/\(id)" ? png : nil }
        tv.load("![a](feather://attachment/\(id))")
        #expect(spacingBefore(tv, at: 0) == CGFloat(124))   // placeholder until loaded
        #expect(await waitFor({ spacingBefore(tv, at: 0) == CGFloat(228) }, timeout: 15))   // generous: the full suite keeps the main actor busy
        #expect(tv.imageCache.image(for: png) != nil)
    }

    @Test func missingAndOversizedAttachments() async {
        let big = makePNG(width: 4000, height: 4000)
        let pdf = FileManager.default.temporaryDirectory.appending(path: "FN-\(UUID().uuidString).pdf")
        try! Data("%PDF-1.4 not really".utf8).write(to: pdf)
        let text = "![big](feather://attachment/BIG)\n\n![gone](feather://attachment/GONE)\n\n![doc](feather://attachment/PDF)\n\n[file](feather://attachment/MISSING) and [x](feather://attachment/01JC8ZQ6V4N1XG2H3K5M7P9R0T)"
        let tv = EditorTextView.make()
        tv.setFrameSize(NSSize(width: 800, height: 600))
        tv.resolveAttachment = { url in
            switch url { case "feather://attachment/BIG": big; case "feather://attachment/PDF": pdf; default: nil }
        }
        tv.load(text)
        #expect(await waitFor({ spacingBefore(tv, at: 0) == CGFloat(588) }, timeout: 15))   // scaled down to the measure
        let gone = (text as NSString).range(of: "![gone]").location
        #expect(spacingBefore(tv, at: gone) == CGFloat(124))
        let doc = (text as NSString).range(of: "![doc]").location
        _ = await waitFor({ false }, timeout: 0.3)
        #expect(spacingBefore(tv, at: doc) == CGFloat(124))
        #expect(Array(tv.string.utf8) == Array(text.utf8))
        let chip = (text as NSString).range(of: "file").location
        #expect(tv.textStorage?.attribute(.featherChip, at: chip, effectiveRange: nil) as? String == "feather://attachment/MISSING")
        tv.displayIfNeeded()   // drawing with missing files must not crash
    }

    @Test func dropInsertsSnippetsAsOneUndo() {
        let tv = EditorTextView.make()
        tv.load("before\nafter")
        tv.insertAttachmentSnippets(["![a](feather://attachment/A)", "[b.pdf](feather://attachment/B)"], at: NSRange(location: 6, length: 0))
        #expect(tv.string == "before\n![a](feather://attachment/A)\n[b.pdf](feather://attachment/B)\nafter")
        tv.undoManager?.undo()
        #expect(tv.string == "before\nafter")
        tv.load("")
        tv.insertAttachmentSnippets(["[x](feather://attachment/X)"], at: NSRange(location: 0, length: 0))
        #expect(tv.string == "[x](feather://attachment/X)")
    }
}
