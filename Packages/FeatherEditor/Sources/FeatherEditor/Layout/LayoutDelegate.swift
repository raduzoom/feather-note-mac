import AppKit

/// Gives every paragraph a DecoratedLayoutFragment.
@MainActor
final class LayoutDelegate: NSObject, @preconcurrency NSTextLayoutManagerDelegate {
    weak var editor: EditorTextView?

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.theme = editor?.theme ?? .standard
        if let editor {
            fragment.imageProvider = { [weak editor] url in
                MainActor.assumeIsolated { editor.flatMap { e in e.resolveAttachment(url).flatMap { e.imageCache.image(for: $0) } } }
            }
            fragment.chipProvider = { [weak editor] url in
                MainActor.assumeIsolated { editor?.chipInfo(for: url) ?? ChipInfo(badge: "?", isPDF: false, missing: true) }
            }
        }
        return fragment
    }
}
