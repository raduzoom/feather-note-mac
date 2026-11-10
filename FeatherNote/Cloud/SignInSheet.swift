import SwiftUI

/// Sign in on this Mac, or with the recovery key (desktop-signin-* boards).
struct SignInSheet: View {
    @Bindable var flow: SignInFlow
    var close: () -> Void

    var body: some View {
        if let count = flow.mergePrompt {
            CloudSheetFrame(step: nil, title: "Add this Mac's notes?") {
                Text("This Mac already has \(count) \(count == 1 ? "note" : "notes"). Add them to your Feather Cloud account? They upload encrypted, alongside the notes already there.")
                    .font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
            } buttons: {
                Button("Cancel") { Task { await flow.cancelMerge(); close() } }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                WorkingButton(title: "Add Notes and Sign In", workingTitle: "Signing In…", working: flow.working, enabled: true) {
                    Task { await flow.confirmMerge(); close() }
                }
            }
        } else {
            switch flow.mode {
            case .password: passwordStep
            case .recoveryKey: recoveryStep
            case .newPassword: newPasswordStep
            }
        }
    }

    private var passwordStep: some View {
        CloudSheetFrame(step: nil, title: "Sign in") {
            VStack(alignment: .leading, spacing: Spacing.s16) {
                Text("Your notes will download and decrypt on this Mac.").font(Theme.uiLabel).foregroundStyle(Theme.textBody)
                LabeledInput(label: "Email", text: $flow.email, prompt: "you@example.com")
                LabeledInput(label: "Password", text: $flow.password, secure: true)
                ErrorLine(text: flow.error)
            }
        } buttons: {
            Button("Use Recovery Key Instead") { flow.useRecoveryKey() }.buttonStyle(.link)
            Spacer()
            Button("Cancel", action: close).buttonStyle(SecondaryButtonStyle())
            WorkingButton(title: "Sign In", workingTitle: "Signing In…", working: flow.working,
                          enabled: !flow.trimmedEmail.isEmpty && !flow.password.isEmpty) {
                Task { await flow.signIn(); if flow.done { close() } }
            }
        }
    }

    private var recoveryStep: some View {
        CloudSheetFrame(step: nil, title: "Enter your recovery key") {
            VStack(alignment: .leading, spacing: Spacing.s16) {
                Text("It's the 28-character key you saved when you set up Feather Cloud\(flow.trimmedEmail.isEmpty ? "" : " for \(flow.trimmedEmail)"). You can paste it all at once.")
                    .font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
                if flow.trimmedEmail.isEmpty || flow.mode == .recoveryKey { LabeledInput(label: "Email", text: $flow.email) }
                LabeledInput(label: "Recovery key, 7 groups of 4", text: $flow.recoveryText, prompt: "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX")
                    .font(.system(.body, design: .monospaced))
                ErrorLine(text: flow.error)
                Text(AccountCopy.lostBoth).font(Theme.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            Button("Back") { flow.mode = .password }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            WorkingButton(title: "Continue", workingTitle: "Checking…", working: flow.working,
                          enabled: !flow.recoveryText.isEmpty && !flow.trimmedEmail.isEmpty) { Task { await flow.submitRecoveryKey() } }
        }
    }

    private var newPasswordStep: some View {
        CloudSheetFrame(step: nil, title: "Choose a new password") {
            VStack(alignment: .leading, spacing: Spacing.s16) {
                Label("Recovery key accepted", systemImage: "checkmark.seal").font(Theme.uiLabelStrong).foregroundStyle(Theme.accent)
                LabeledInput(label: "New password", text: $flow.newPassword, secure: true)
                if let label = PasswordStrength(flow.newPassword).label {
                    Text(label).font(Theme.uiLabelStrong).foregroundStyle(Theme.accent)
                }
                LabeledInput(label: "Confirm new password", text: $flow.confirmPassword, secure: true)
                Text("Your recovery key stays the same. Your other devices will ask for the new password the next time they sync.")
                    .font(Theme.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ErrorLine(text: flow.error)
            }
        } buttons: {
            Spacer()
            Button("Cancel", action: close).buttonStyle(SecondaryButtonStyle())
            WorkingButton(title: "Set Password and Sign In", workingTitle: "Signing In…", working: flow.working, enabled: flow.newPasswordReady) {
                Task { await flow.setNewPassword(); if flow.done { close() } }
            }
        }
    }
}
