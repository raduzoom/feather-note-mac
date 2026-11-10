import SwiftUI

/// Feather Cloud onboarding, steps 1–5 (desktop-onboarding-* boards).
struct OnboardingSheet: View {
    @Bindable var flow: OnboardingFlow
    var close: () -> Void
    var signIn: () -> Void

    var body: some View {
        CloudSheetFrame(step: "Step \(flow.step) of 5", title: title) {
            content
        } buttons: {
            buttons
        }
    }

    private var title: String {
        switch flow.step {
        case 1: "Your notes, on every device"
        case 2: "Create your account"
        case 3: "Check your email"
        case 4: AccountCopy.recoveryTitle
        default: "You're all set"
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case 1:
            VStack(alignment: .leading, spacing: Spacing.s16) {
                Text(AccountCopy.encryption).font(Theme.uiLabel).foregroundStyle(Theme.textBody)
                ForEach(flow.introBullets, id: \.self) { bullet($0) }
                Text("Takes about 2 minutes").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
        case 2:
            VStack(alignment: .leading, spacing: Spacing.s16) {
                LabeledInput(label: "Email", text: $flow.email, prompt: "you@example.com")
                LabeledInput(label: "Password", text: $flow.password, secure: true)
                HStack {
                    Text(AccountCopy.passwordHint).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let label = flow.strength.label { Text(label).font(Theme.uiLabelStrong).foregroundStyle(Theme.accent) }
                }
                Text(AccountCopy.passwordNote).font(Theme.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ErrorLine(text: flow.error)
            }
        case 3:
            VStack(alignment: .leading, spacing: Spacing.s16) {
                Text(AccountCopy.verifySent(flow.email)).font(Theme.uiLabel).foregroundStyle(Theme.textBody)
                LabeledInput(label: "Verification code", text: $flow.code, prompt: "123456")
                HStack(spacing: Spacing.s4) {
                    Text("Didn't get it? Check spam, or").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                    Button("Resend Code") { Task { await flow.resend() } }.buttonStyle(.link).font(Theme.meta)
                }
                ErrorLine(text: flow.error)
            }
        case 4:
            VStack(alignment: .leading, spacing: Spacing.s16) {
                Text(AccountCopy.recoveryBody).font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
                if let text = flow.recoveryText { RecoveryKeyView(text: text) }
                Toggle(AccountCopy.recoveryConfirm, isOn: $flow.savedConfirmed)
            }
        default:
            DoneStep(cloud: flow.cloud, email: flow.email)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch flow.step {
        case 1:
            Spacer()
            Button("Sign In…", action: signIn).buttonStyle(SecondaryButtonStyle())
            WorkingButton(title: "Create Account", workingTitle: "Create Account", working: false, enabled: true) { Task { await flow.next() } }
        case 5:
            Spacer()
            WorkingButton(title: "Start Writing", workingTitle: "Start Writing", working: false, enabled: true, action: close)
        default:
            if flow.step == 2 {
                Button("Cancel", action: close).buttonStyle(SecondaryButtonStyle())
            } else if flow.canGoBack {
                Button("Back") { flow.back() }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            WorkingButton(title: flow.step == 3 ? "Verify Email" : "Continue",
                          workingTitle: flow.step == 3 ? "Verifying…" : "Creating Account…",
                          working: flow.working, enabled: flow.canContinue) { Task { await flow.next() } }
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle").font(Theme.uiLabel).foregroundStyle(Theme.textBody)
    }
}

/// Step 5: the trial date, the first sync's progress, and what to do next.
private struct DoneStep: View {
    var cloud: CloudModel
    var email: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text(intro).font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
            if case .syncing(let done, let total) = cloud.status {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    Text("First sync").font(Theme.uiLabelStrong)
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done) of \(total) notes").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Next: add your other devices").font(Theme.uiLabelStrong)
            Text("Install FeatherMark on your iPhone, iPad, Windows PC or Android phone and sign in with \(email).")
                .font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intro: String {
        let tail = "Your notes are being encrypted and uploaded now. You can keep writing while this runs."
        guard let ends = cloud.plan?.trialEndsAt else { return tail }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM"
        return "Your trial runs until \(f.string(from: ends)). " + tail
    }
}
