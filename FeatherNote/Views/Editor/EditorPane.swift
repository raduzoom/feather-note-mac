import FeatherCore
import SwiftUI

/// The right column: the open note, the Trash banner, or an empty state.
struct EditorPane: View {
    @Bindable var model: AppModel
    var dialogs: Dialogs

    var body: some View {
        Group {
            if let editor = model.editor {
                VStack(alignment: .leading, spacing: 0) {
                    if editor.isTrashed { TrashBanner(model: model, dialogs: dialogs, editor: editor) }
                    header(editor)
                    PlainTextEditor(text: Binding(get: { model.editor?.body ?? "" }, set: { model.editBody($0) }),
                                    isEditable: !editor.isTrashed)
                        .id(editor.id)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.glassEditor)
    }

    private func header(_ editor: EditorState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            TitleEditor(text: Binding(get: { model.editor?.title ?? "" }, set: { model.editTitle($0) }),
                        isEditable: !editor.isTrashed, wantsFocus: model.titleWantsFocus, onFocused: { model.titleTookFocus() })
                .id(editor.id)
            HStack(spacing: Spacing.s8) {
                ForEach(editor.tagIDs.compactMap { id in model.tagName(id).map { (id, $0) } }.sorted { $0.1 < $1.1 }, id: \.0) { _, name in
                    Text("#\(name)")
                        .font(Theme.meta.weight(.semibold))
                        .foregroundStyle(Theme.accentOnTint)
                        .padding(.horizontal, Spacing.s8)
                        .frame(height: 24)
                        .background(Theme.accentTint, in: Capsule())
                }
                Text(Formatting.editedLine(editor.modified, now: .now))
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.top, Spacing.s24)
        .padding(.bottom, Spacing.s16)
        .frame(maxWidth: 560 + 2 * Spacing.s40)
        .padding(.horizontal, Spacing.s40)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private var empty: some View {
        if model.emptyState == .firstLaunch {
            EmptyStateView(title: "A quiet place to write.",
                           message: "Your notes stay on this Mac. No account, no network, nothing in the way.",
                           primary: ("Write Your First Note", { Task { await model.newNote() } }),
                           secondary: ("Import Notes…", { FileActions.importNotes(model: model, dialogs: dialogs) }),
                           footnote: "Or press ⌘N anytime.")
        } else {
            EmptyStateView(title: "No note open", message: "Select a note, or press ⌘N to write a new one.")
        }
    }
}

/// Shown above a note that is in the Trash (ui-copy "Trash").
struct TrashBanner: View {
    let model: AppModel
    let dialogs: Dialogs
    let editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            HStack(alignment: .top, spacing: Spacing.s16) {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text("This note is in the Trash").font(Theme.uiLabelStrong).foregroundStyle(Theme.textPrimary)
                    Text("It's read-only. Restore it to edit.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(2)   // never .fixedSize here: min-size probing at tiny widths made it huge
            }
            HStack(spacing: Spacing.s8) {
            Spacer()
            Button("Delete Permanently…") {
                dialogs.confirm(Formatting.deletePermanentlyConfirmation(title: editor.title)) {
                    await model.deletePermanently(editor.id)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
            Button("Restore Note") { Task { await model.restore(editor.id) } }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize()
            }
        }
        .padding(Spacing.s16)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Spacing.s24)
        .padding(.top, Spacing.s16)
    }
}
