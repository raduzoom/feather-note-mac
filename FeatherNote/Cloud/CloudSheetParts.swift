import SwiftUI

/// The shared frame of the Feather Cloud sheets: overline, step, title, body, buttons (onboarding boards).
struct CloudSheetFrame<Content: View, Buttons: View>: View {
    var step: String?
    var title: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            VStack(alignment: .leading, spacing: Spacing.s8) {
                HStack {
                    Text("Feather Cloud").font(Theme.overline).foregroundStyle(Theme.accent).textCase(.uppercase)
                    Spacer()
                    if let step { Text(step).font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                }
                Text(title).font(Theme.panelTitle).foregroundStyle(Theme.textPrimary)
            }
            content
            Spacer(minLength: 0)
            HStack(spacing: Spacing.s8) { buttons }
        }
        .padding(Spacing.s32)
        .frame(width: 520, height: 520, alignment: .topLeading)
        .background(Theme.glassEditor)
        .background(GlassBackground())
    }
}

/// A label + field pair at native height.
struct LabeledInput: View {
    var label: String
    @Binding var text: String
    var secure = false
    var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(label).font(Theme.uiLabelStrong).foregroundStyle(Theme.textPrimary)
            Group {
                if secure { SecureField(label, text: $text, prompt: Text(prompt)) } else { TextField(label, text: $text, prompt: Text(prompt)) }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .controlSize(.large)
        }
    }
}

/// Error text in the danger colour, announced to VoiceOver.
struct ErrorLine: View {
    var text: String?
    var body: some View {
        if let text {
            Text(text).font(Theme.uiLabel).foregroundStyle(Theme.dangerText).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// The primary action, with its "-ing" label while it works.
struct WorkingButton: View {
    var title: String
    var workingTitle: String
    var working: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(working ? workingTitle : title, action: action)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!enabled || working)
            .keyboardShortcut(.defaultAction)
    }
}
