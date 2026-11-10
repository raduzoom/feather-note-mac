import AppKit
import Testing
@testable import FeatherEditor

/// Continuity Camera: "Scan Documents" delivers a PDF; it becomes a chip in the note.
@MainActor @Suite struct ScanTests {
    func onePagePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    @Test func pdfScanBecomesAttachmentChip() async {
        let tv = makeView("Receipt:")
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        var received: [URL] = []
        tv.importFiles = { urls in
            received = urls
            return ["[\(urls[0].lastPathComponent)](feather://attachment/01JC8ZT9HJ2KM3MN4PQ5RS6TV7)"]
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("FNScan-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(onePagePDF(), forType: .pdf)
        #expect(tv.readSelection(from: pb, type: .pdf))
        _ = await waitFor({ tv.string.contains("feather://") }, timeout: 15)
        #expect(received.count == 1)
        let name = received.first?.lastPathComponent ?? ""
        #expect(name.range(of: #"^Scan \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.pdf$"#, options: .regularExpression) != nil, "named \(name)")
        #expect(tv.string.contains("[Scan "))
    }

    @Test func continuityRequestorAcceptsImagesAndPDF() {
        let tv = makeView("")
        #expect(tv.validRequestor(forSendType: nil, returnType: .pdf) as AnyObject? === tv)
        #expect(tv.validRequestor(forSendType: nil, returnType: .png) as AnyObject? === tv)
        #expect(tv.validRequestor(forSendType: nil, returnType: .tiff) as AnyObject? === tv)
        #expect(tv.validRequestor(forSendType: nil, returnType: .string) as AnyObject? !== tv)
    }
}

/// The right-click menu offers Continuity Camera (Take Photo, Scan Documents, Add Sketch) where the caret is.
@MainActor @Suite struct ScanMenuTests {
    @Test func editorContextMenuOffersContinuityCamera() throws {
        let tv = makeView("Receipt:")
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(tv.menu(for: event))
        #expect(menu.items.contains { $0.identifier == NSMenuItem.importFromDeviceIdentifier })
    }
}
