import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

/// Real exports (a folder of .enex and Notion .zip files, never committed: they hold personal data), each imported
/// into a temporary library: every note present, every attachment opening. Opt-in, prints counts only:
/// FEATHER_REAL_EXPORTS=<folder> swift test --package-path Packages/FeatherImport --filter realExportsImportCompletely
@Test(.enabled(if: ProcessInfo.processInfo.environment["FEATHER_REAL_EXPORTS"] != nil))
func realExportsImportCompletely() async throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FEATHER_REAL_EXPORTS"]!)
    for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where ["enex", "zip"].contains(url.pathExtension) {
        let isZip = url.pathExtension == "zip"
        let expected: Int
        if isZip {
            let list = Process(); list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo"); list.arguments = ["-1", url.path]
            let out = Pipe(); list.standardOutput = out; try list.run(); list.waitUntilExit()
            expected = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").filter { $0.hasSuffix(".md") }.count
        } else {
            expected = String(decoding: try Data(contentsOf: url), as: UTF8.self).components(separatedBy: "<note>").count - 1
        }
        let bundle = isZip ? try NotionReader.read(url) : try ENEXReader.read(url)
        let sizes = bundle.notes.flatMap(\.attachments).map { (try? $0.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        let lib = try Library.open(at: FileManager.default.temporaryDirectory.appending(path: "FNReal-\(UUID().uuidString)"))
        let report = try await lib.importBundle(bundle, into: nil)
        var opened = 0
        for a in try await lib.attachments() {
            if let f = try await lib.attachmentFileURL(a.id), FileManager.default.fileExists(atPath: f.path) { opened += 1 }
        }
        FileHandle.standardError.write(Data("REAL \(url.pathExtension): source \(expected) notes, imported \(report.notes); attachments \(report.attachments) (opened \(opened), source sizes \(sizes.count)); preserved \(report.preserved.count)\n".utf8))
        #expect(report.notes == expected)
        #expect(opened == report.attachments)
    }
}
