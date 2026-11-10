import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

#if DEBUG
private let importBudget: Double = 150
#else
private let importBudget: Double = 15
#endif

/// Release gate: 5,000 notes and 500 images of 50 KB read and import in under 15 s.
@Suite(.serialized) struct ImportPerformanceTests {
    @Test func fiveThousandNotesWithinBudget() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FNPerf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let enex = dir.appending(path: "Big.enex")
        FileManager.default.createFile(atPath: enex.path, contents: nil)
        let h = try FileHandle(forWritingTo: enex)
        try h.write(contentsOf: Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<en-export>".utf8))
        let image = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let b64 = image.base64EncodedString(options: .lineLength76Characters)
        for i in 1...5_000 {
            var note = "<note><title>Note \(i)</title><created>20251109T135200Z</created><tag>t\(i % 20)</tag><content><![CDATA[<en-note>"
            note += "<div>Paragraph \(i) with <b>bold</b> and <i>italic</i> text.</div><ul><li>one</li><li>two</li></ul>"
            if i % 10 == 0 { note += "<en-media type=\"image/png\" hash=\"x\"/>" }
            note += "</en-note>]]></content>"
            if i % 10 == 0 { note += "<resource><data encoding=\"base64\">\(b64)</data><mime>image/png</mime></resource>" }
            note += "</note>\n"
            try h.write(contentsOf: Data(note.utf8))
        }
        try h.write(contentsOf: Data("</en-export>".utf8))
        try h.close()

        let lib = try Library.open(at: dir.appending(path: "lib"))
        let clock = ContinuousClock()
        let start = clock.now
        let bundle = try ENEXReader.read(enex)
        let report: ImportReport? = try await lib.importBundle(bundle, into: nil)
        let time = clock.now - start
        let seconds = Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
        FileHandle.standardError.write(Data("PERF import 5,000 notes + 500 images: \(seconds) s\n".utf8))
        #expect(report?.notes == 5_000 && report?.attachments == 500)
        #expect(seconds < importBudget)
    }
}
