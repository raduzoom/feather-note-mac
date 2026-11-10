import FeatherCore
import FeatherImport
import Foundation

/// What can be imported (board `desktop-import-source`).
enum ImportSource: Equatable {
    case evernote(URL), notion(URL), markdownFolder(URL)

    /// `.enex` → Evernote, `.zip` → Notion, a folder → Markdown folder.
    init?(url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { self = .markdownFolder(url); return }
        switch url.pathExtension.lowercased() {
        case "enex": self = .evernote(url)
        case "zip": self = .notion(url)
        default: return nil
        }
    }

    var url: URL {
        switch self { case .evernote(let u), .notion(let u), .markdownFolder(let u): u }
    }
}

enum ImportState: Equatable {
    case running(ImportProgress, sourceName: String, sizeText: String)
    case finished(ImportReport)
    case failed(String)
}

extension AppModel {
    /// Imports `source` in the background, publishing progress in `importState`. One transaction: cancelling
    /// or a failure imports nothing.
    func startImport(_ source: ImportSource) {
        importTask?.cancel()
        let name = source.url.lastPathComponent
        let size = (try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        importState = .running(ImportProgress(notesDone: 0, notesTotal: 0, attachments: 0, current: ""), sourceName: name, sizeText: size)
        importStarted = Date()
        let library = self.library
        let delay = importNoteDelay
        let model = self   // main-actor isolated, so Sendable
        importTask = Task { [weak self] in
            await self?.flush()
            do {
                let report: ImportReport
                switch source {
                case .markdownFolder(let url):
                    report = try await library.importMarkdownFolder(from: url)
                case .evernote(let url), .notion(let url):
                    let isNotion = { if case .notion = source { true } else { false } }()
                    let bundle = try await Task.detached(priority: .userInitiated) {
                        isNotion ? try NotionReader.read(url) : try ENEXReader.read(url)
                    }.value
                    if Task.isCancelled {
                        bundle.scratch.map { try? FileManager.default.removeItem(at: $0) }
                        throw CancellationError()
                    }
                    report = try await library.importBundle(bundle, into: nil) { p in
                        if delay > 0 { Thread.sleep(forTimeInterval: delay) }   // tests only
                        Task { @MainActor in model.updateImportProgress(p, sourceName: name, sizeText: size) }
                    }
                }
                guard let self else { return }
                await refresh()
                importState = .finished(report)
            } catch is CancellationError {
                self?.importState = nil
                await self?.refresh()
            } catch {
                self?.importState = .failed(Self.importMessage(error, name: name))
            }
        }
    }

    private func updateImportProgress(_ p: ImportProgress, sourceName: String, sizeText: String) {
        guard case .running = importState else { return }   // a late update after the import finished
        importState = .running(p, sourceName: sourceName, sizeText: sizeText)
    }

    func cancelImport() { importTask?.cancel() }

    /// Selects what was imported: its top notebook, or All Notes.
    func showImportedNotes() async {
        if case .finished(let report) = importState, let top = report.topNotebookID {
            await select(.notebook(top))
        } else {
            await select(.all)
        }
    }

    func finishImport() {
        importState = nil
        importTask = nil
    }

    static func importMessage(_ error: Error, name: String) -> String {
        switch error {
        case ENEXError.notENEX:
            return "“\(name)” isn't an Evernote export. In Evernote, right-click a notebook, choose Export Notebook…, and pick ENEX."
        case ENEXError.malformed(let line):
            return "“\(name)” isn't a complete Evernote export: it breaks off at line \(line). Export it again and retry."
        case NotionError.notANotionExport:
            return "“\(name)” isn't a Notion export. In Notion, open Settings, choose Export all workspace content, and pick Markdown & CSV."
        default:
            return "Couldn't import “\(name)”: \(error.localizedDescription)"
        }
    }
}
