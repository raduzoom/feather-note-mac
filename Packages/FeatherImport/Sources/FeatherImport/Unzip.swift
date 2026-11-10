import Foundation

enum Unzip {
    enum UnzipError: LocalizedError, Equatable {
        case failed(String)
        var errorDescription: String? { "it isn't a .zip file that can be opened. Export it again from Notion and retry." }
    }

    /// Extracts `zip` into `folder` with /usr/bin/ditto. If the result holds only zips (Notion's multi-part
    /// exports), each of those is extracted into the same folder too.
    static func extract(_ zip: URL, into folder: URL) throws {
        try ditto(zip, folder)
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent != "__MACOSX" }
        if !items.isEmpty, items.allSatisfy({ $0.pathExtension.lowercased() == "zip" }) {
            for inner in items {
                try ditto(inner, folder)
                try fm.removeItem(at: inner)
            }
        }
    }

    private static func ditto(_ zip: URL, _ folder: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UnzipError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
