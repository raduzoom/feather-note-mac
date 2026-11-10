import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The recovery key in 7 monospaced groups of 4, with Copy, Print… and Save as PDF… (step 4 board).
struct RecoveryKeyView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            RecoveryKeyCard(text: text)
            HStack(spacing: Spacing.s8) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Print…") { Self.print(text) }
                Button("Save as PDF…") { Self.savePDF(text) }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// The card printed and saved: the key, with the account's warning.
    @MainActor static func page(_ text: String) -> NSView {
        let view = NSHostingView(rootView: RecoveryKeyCard(text: text, printable: true).padding(Spacing.s48).frame(width: 612))
        view.frame = NSRect(x: 0, y: 0, width: 612, height: 360)
        return view
    }

    @MainActor static func print(_ text: String) {
        NSPrintOperation(view: page(text)).run()
    }

    @MainActor static func savePDF(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Feather Note recovery key.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let view = page(text)
        try? view.dataWithPDF(inside: view.bounds).write(to: url)
    }
}

struct RecoveryKeyCard: View {
    var text: String
    var printable = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            if printable {
                Text("Feather Note recovery key").font(Theme.panelTitle)
                Text(AccountCopy.recoveryBody).font(Theme.uiLabel).fixedSize(horizontal: false, vertical: true)
            }
            Text(text)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(Spacing.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Recovery key: \(text.split(separator: "-").joined(separator: ", "))")
        }
    }
}
