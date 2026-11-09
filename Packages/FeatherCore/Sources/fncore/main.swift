// fncore: a small command-line harness for FeatherCore.
// Exit codes: 0 success, 1 error (message on stderr), 2 bad usage.

import Foundation
@_spi(Testing) import FeatherCore

let usage = """
    usage: fncore init <dir>
           fncore add <dir> --title <title> [--notebook <name>] [--tag <name>]...   (body from stdin)
           fncore list <dir>
           fncore search <dir> <query>...
           fncore export <dir> <destination>
           fncore import <dir> <source>
    """

struct UsageError: Error {}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

func run(_ args: [String]) async throws {
    guard let command = args.first else { throw UsageError() }
    let rest = Array(args.dropFirst())
    switch command {
    case "init":
        guard rest.count == 1 else { throw UsageError() }
        print(try Library.open(at: url(rest[0])).id)

    case "add":
        guard let dir = rest.first else { throw UsageError() }
        var title: String?
        var notebookName: String?
        var tagNames: [String] = []
        var i = 1
        while i < rest.count {
            guard i + 1 < rest.count else { throw UsageError() }
            switch rest[i] {
            case "--title": title = rest[i + 1]
            case "--notebook": notebookName = rest[i + 1]
            case "--tag": tagNames.append(rest[i + 1])
            default: throw UsageError()
            }
            i += 2
        }
        guard let title else { throw UsageError() }
        let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let lib = try Library.open(at: url(dir))
        var notebookID: ULID?
        if let notebookName {
            if let existing = try await lib.notebooks().first(where: { $0.name == notebookName && $0.parentID == nil }) {
                notebookID = existing.id
            } else {
                notebookID = try await lib.createNotebook(name: notebookName, parentID: nil).id
            }
        }
        var tagIDs: Set<ULID> = []
        for name in tagNames {
            if let existing = try await lib.tag(named: name) { tagIDs.insert(existing.id) } else { tagIDs.insert(try await lib.createTag(name: name).id) }
        }
        print(try await lib.createNote(title: title, body: body, notebookID: notebookID, tagIDs: tagIDs).id)

    case "list":
        guard rest.count == 1 else { throw UsageError() }
        for note in try await Library.open(at: url(rest[0])).notes(in: .all) { print("\(note.id)\t\(note.title)") }

    case "search":
        guard rest.count >= 2 else { throw UsageError() }
        let lib = try Library.open(at: url(rest[0]))
        for hit in try await lib.search(rest.dropFirst().joined(separator: " ")) {
            print("\(hit.note.id)\t\(hit.note.title)\t\(hit.snippet.replacingOccurrences(of: "\n", with: " "))")
        }

    case "export":
        guard rest.count == 2 else { throw UsageError() }
        let r = try await Library.open(at: url(rest[0])).exportMarkdown(to: url(rest[1]))
        print("root: \(r.root.path)\nnotes: \(r.notes)\nnotebooks: \(r.notebooks)\nattachments: \(r.attachments)")

    case "import":
        guard rest.count == 2 else { throw UsageError() }
        let r = try await Library.open(at: url(rest[0])).importMarkdownFolder(from: url(rest[1]))
        print("notes: \(r.notes)\nnotebooks: \(r.notebooks)\nattachments: \(r.attachments)")
        for s in r.skipped { print("skipped: \(s.path) (\(s.reason.rawValue))") }

    // Undocumented, for the crash tests: die with SIGKILL just before COMMIT.
    case "_crash-during-save":
        guard rest.count == 3, let id = ULID(string: rest[1]) else { throw UsageError() }
        let lib = try Library.open(at: url(rest[0]))
        await lib.setBeforeCommitHook { kill(getpid(), SIGKILL) }
        try await lib.updateNote(id, body: rest[2])

    case "_crash-during-import":
        guard rest.count == 2 else { throw UsageError() }
        let lib = try Library.open(at: url(rest[0]))
        await lib.setBeforeCommitHook { kill(getpid(), SIGKILL) }
        _ = try await lib.importMarkdownFolder(from: url(rest[1]))

    default:
        throw UsageError()
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch is UsageError {
    fail(usage, code: 2)
} catch {
    fail("fncore: \(error)", code: 1)
}
