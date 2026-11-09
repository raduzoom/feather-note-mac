import FeatherCore
import SwiftUI

/// One note in the list: letter tile, serif title, preview or search snippet, "date · notebook", pin star.
struct NoteRow: View {
    let summary: NoteSummary
    let notebookName: String?
    let snippet: (text: String, matches: [Range<Int>])?
    let trashRetentionDays: Int
    /// `.increased` when the row is selected in a focused list (the accent fill).
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { prominence == .increased }

    // Semantic styles (tokens: text.primary → labelColor, text.secondary → secondaryLabelColor)
    // so the row inverts on the selection fill like every native list.
    private var titleColor: HierarchicalShapeStyle { .primary }
    private var secondaryColor: HierarchicalShapeStyle { .secondary }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s16) {
            Text(String(Formatting.displayTitle(summary.title).prefix(1)).uppercased())
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(selected ? .white : Theme.accentOnTint)
                .frame(width: 48, height: 48)
                .background(selected ? Color.white.opacity(0.18) : Theme.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(Formatting.displayTitle(summary.title))
                    .font(Theme.listTitle)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let snippet {
                    Text(highlighted(snippet.text, snippet.matches))
                        .font(Theme.meta)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(2)
                } else if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(Theme.meta)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(2)
                }
                Text(meta)
                    .font(Theme.meta)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if summary.pinned {
                Image(systemName: "star.fill")
                    .foregroundStyle(selected ? .white : Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.s8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatting.rowAccessibilityLabel(summary: summary, notebookName: notebookName, now: .now))
    }

    private var meta: String {
        if let trashedAt = summary.trashedAt {
            return Formatting.trashMeta(trashedAt: trashedAt, retentionDays: trashRetentionDays, now: .now)
        }
        return Formatting.noteMeta(summary: summary, notebookName: notebookName, now: .now)
    }

    private func highlighted(_ text: String, _ matches: [Range<Int>]) -> AttributedString {
        var s = AttributedString(text)
        let chars = Array(text)
        for m in matches where m.upperBound <= chars.count {
            let start = s.index(s.startIndex, offsetByCharacters: m.lowerBound)
            let end = s.index(s.startIndex, offsetByCharacters: m.upperBound)
            s[start..<end].backgroundColor = Theme.searchMatch
            s[start..<end].foregroundColor = Theme.textPrimary
        }
        return s
    }
}
