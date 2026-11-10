import AppKit
import FeatherCore
import SwiftUI
import UniformTypeIdentifiers

/// The import sheet: source picker, progress, report or failure (boards `desktop-import-source`,
/// `desktop-import-progress`, `desktop-import-report`).
struct ImportSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Notes")
                .font(Theme.overline)
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .padding(.bottom, Spacing.s8)
            switch model.importState {
            case .running(let p, let name, let size): ImportProgressView(model: model, progress: p, sourceName: name, sizeText: size)
            case .finished(let report): ImportReportView(model: model, report: report)
            case .failed(let message): ImportFailedView(model: model, message: message)
            case nil: ImportSourceView(model: model)
            }
        }
        .padding(Spacing.s32)
        .frame(width: 560)
    }
}

private enum SourceKind: CaseIterable, Identifiable {
    case evernote, notion, folder
    var id: Self { self }
    var name: String { switch self { case .evernote: "Evernote"; case .notion: "Notion"; case .folder: "Markdown folder" } }
    var badge: String? { switch self { case .evernote: ".enex"; case .notion: ".zip"; case .folder: nil } }
    var hint: String {
        switch self {
        case .evernote: "In Evernote, right-click a notebook, choose Export Notebook…, and pick ENEX."
        case .notion: "In Notion, open Settings, choose Export all workspace content, pick Markdown & CSV, and keep the .zip."
        case .folder: "Any folder of .md files, from Obsidian, Bear or anywhere else. Subfolders become notebooks."
        }
    }
    var button: String { switch self { case .evernote: "Choose .enex File…"; case .notion: "Choose .zip File…"; case .folder: "Choose Folder…" } }
    var symbol: String { switch self { case .evernote: "doc.text"; case .notion: "doc.zipper"; case .folder: "folder" } }
}

private struct ImportSourceView: View {
    let model: AppModel
    @State private var kind: SourceKind = .evernote

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Bring your notes in").font(Theme.panelTitle).foregroundStyle(Theme.textPrimary)
            Text("Everything is imported to this Mac and nothing is changed in the original app.")
                .font(Theme.uiLabel).foregroundStyle(Theme.textSecondary)
            Text("Import from").font(Theme.uiLabelStrong).foregroundStyle(Theme.textPrimary)
            VStack(spacing: Spacing.s8) {
                ForEach(SourceKind.allCases) { k in
                    Button { kind = k } label: {
                        HStack(alignment: .top, spacing: Spacing.s16) {
                            Image(systemName: k.symbol).font(.system(size: 20)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: Spacing.s8) {
                                    Text(k.name).font(Theme.uiLabelStrong)
                                    if let badge = k.badge {
                                        Text(badge).font(Theme.meta).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                Text(k.hint).font(Theme.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Spacing.s16)
                        .contentShape(Rectangle())
                        .background(kind == k ? Theme.accentTint : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind == k ? Theme.accent : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(k.name)
                    .accessibilityAddTraits(kind == k ? .isSelected : [])
                }
            }
            Text("Or drop a .enex, .zip or folder anywhere in this window")
                .font(Theme.meta).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel") { model.showImportSource = false }.keyboardShortcut(.cancelAction)
                Button(kind.button) { choose() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Import Notes"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        switch kind {
        case .evernote: panel.allowedContentTypes = [UTType(filenameExtension: "enex") ?? .xml]
        case .notion: panel.allowedContentTypes = [.zip]
        case .folder: panel.canChooseDirectories = true; panel.canChooseFiles = false
        }
        guard panel.runModal() == .OK, let url = panel.url, let source = ImportSource(url: url) else { return }
        model.showImportSource = false
        model.startImport(source)
    }
}

private struct ImportProgressView: View {
    let model: AppModel
    let progress: ImportProgress
    let sourceName: String
    let sizeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Importing your notes…").font(Theme.panelTitle).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceName).font(Theme.uiLabelStrong)
                Text([sizeText, progress.notesTotal > 0 ? "\(progress.notesTotal.formatted()) notes" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
            if progress.notesTotal > 0 {
                ProgressView(value: Double(progress.notesDone), total: Double(progress.notesTotal))
                Text(Formatting.importProgressLine(progress)).font(Theme.uiLabel)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Reading the export…").font(Theme.uiLabel)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let left = Formatting.timeLeft(done: progress.notesDone, total: progress.notesTotal,
                                                  elapsed: Date().timeIntervalSince(model.importStarted ?? Date())) {
                    Text(left).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                }
            }
            if !progress.current.isEmpty {
                Text("Now: “\(progress.current)”").font(Theme.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Text("Everything is imported to this Mac. Nothing leaves it.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel Import") { model.cancelImport() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

private struct ImportReportView: View {
    let model: AppModel
    let report: ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Import complete").font(Theme.panelTitle).foregroundStyle(Theme.textPrimary)
            Text(Formatting.importSummary(report)).font(Theme.uiLabel).foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)
            if !report.preserved.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(report.preserved.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.title.isEmpty ? "Untitled" : item.title).font(Theme.uiLabel).lineLimit(1)
                                Spacer()
                                Text(Self.label(item.kind)).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                                Button("Open") { open(item.noteID) }
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if !report.skipped.isEmpty {
                Text(FileActions.importSummary(report).components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                    .font(Theme.meta).foregroundStyle(Theme.textSecondary).lineLimit(8)
            }
            HStack {
                Spacer()
                Button("Close") { model.finishImport() }.keyboardShortcut(.cancelAction)
                Button("Show Imported Notes") {
                    Task {
                        await model.showImportedNotes()
                        model.finishImport()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func label(_ kind: PreservedContent.Kind) -> String {
        switch kind { case .table: "Table"; case .html: "HTML"; case .encrypted: "Encrypted"; case .notionBlock: "Notion block" }
    }

    private func open(_ id: ULID) {
        Task {
            model.finishImport()
            await model.select(.all)
            await model.selectNote(id)
        }
    }
}

private struct ImportFailedView: View {
    let model: AppModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Import didn't finish").font(Theme.panelTitle).foregroundStyle(Theme.textPrimary)
            Text(message).font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
            Text("Nothing was imported.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Close") { model.finishImport() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
