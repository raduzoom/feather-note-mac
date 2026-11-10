import FeatherCore
import FeatherSync
import SwiftUI

/// Settings › Sync, signed out or signed in (desktop-settings-sync-* boards).
struct SyncSettingsView: View {
    @Bindable var model: AppModel
    var cloud: CloudModel { model.cloud }

    var body: some View {
        if let s = cloud.state.signedIn { signedIn(s) } else { signedOut }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Feather Cloud").font(Theme.panelTitle)
            Text("Feather Cloud keeps your notes in sync across your Mac, iPhone, iPad, Windows PC and Android phone. Your notes are encrypted on this device before they're uploaded, so only your devices can read them.")
                .font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
            if let email = cloud.reauthEmail {
                Text("Signed out of Feather Cloud. Sign in again as \(email) to keep syncing; your notes are still on this Mac.")
                    .font(Theme.uiLabel).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
                Button("Sign In…") { open { cloud.showSignIn() } }.buttonStyle(PrimaryButtonStyle())
            } else if cloud.offersTrial {
                HStack(spacing: Spacing.s16) {
                    Label("14 days free", systemImage: "gift")
                    Label("No card needed", systemImage: "creditcard")
                    Label("1 GB during the trial", systemImage: "internaldrive")
                }
                .font(Theme.meta).foregroundStyle(Theme.textSecondary)
                actions
                Text("Running your own server? Enter its address in Advanced.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            } else {
                if cloud.isSelfHosted {
                    Text(selfHostedNote).font(Theme.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                actions
                if !cloud.isSelfHosted {
                    Text("Running your own server? Enter its address in Advanced.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func signedIn(_ s: SignedIn) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            HStack(spacing: Spacing.s16) {
                Text(String(s.email.prefix(1)).uppercased())
                    .font(Theme.uiLabelStrong).foregroundStyle(Theme.onPrimary)
                    .frame(width: 32, height: 32).background(Theme.actionPrimary, in: Circle())
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(s.email).font(Theme.uiLabelStrong)
                    Text(SyncStatusText.make(state: cloud.state, status: cloud.status, plan: cloud.plan,
                                             selfHostedHost: cloud.isSelfHosted ? cloud.server.host : nil, now: Date()).settingsLine)
                        .font(Theme.meta).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Sign Out…") { confirmSignOut() }.buttonStyle(SecondaryButtonStyle())
            }
            if let plan = cloud.plan, plan.quotaBytes > 0 {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    Text(cloud.isSelfHosted ? cloud.server.host : "Feather Cloud").font(Theme.uiLabelStrong)
                    ProgressView(value: Double(plan.usedBytes), total: Double(plan.quotaBytes))
                    Text(CloudFormat.usage(used: plan.usedBytes, quota: plan.quotaBytes)).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text("Devices").font(Theme.uiLabelStrong)
                ForEach(cloud.devices) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(d.name).font(Theme.uiLabel)
                            Text(d.current ? "This Mac" : "Last synced \(CloudFormat.ago(d.lastSeenAt, now: Date()))")
                                .font(Theme.meta).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if !d.current { Button("Revoke…") { confirmRevoke(d) } }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text("Sync conflicts").font(Theme.uiLabelStrong)
                Text("When two devices change a note at once, Feather keeps both. Nothing is overwritten.")
                    .font(Theme.meta).foregroundStyle(Theme.textSecondary)
                ForEach(cloud.conflicts) { c in
                    HStack {
                        Text("\(c.lostName) (renamed on \(c.device))").font(Theme.uiLabel)
                        Spacer()
                        Button("Show") { Task { await model.showConflict(c) } }
                    }
                }
            }
        }
        .task { await cloud.refreshAccount() }
    }

    /// Create (trial or free) and Sign In, worded by CloudModel.signedOutActions.
    private var actions: some View {
        HStack(spacing: Spacing.s8) {
            Button(cloud.signedOutActions[0]) { open { cloud.startTrial() } }.buttonStyle(PrimaryButtonStyle())
            Button(cloud.signedOutActions[1]) { open { cloud.showSignIn() } }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private let selfHostedNote = "A self-hosted server may have different storage limits, and trial and plan details won't appear. Your notes are still encrypted on this device before upload."

    /// The account sheets belong to the main window.
    private func open(_ show: () -> Void) {
        show()
        NSApp.windows.first { $0.title == "Feather Note" }?.makeKeyAndOrderFront(nil)
    }

    private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of Feather Cloud?"
        alert.informativeText = "Your notes stay on this Mac. To sync again, sign in with your password or recovery key."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Task { await cloud.signOut() } }
    }

    private func confirmRevoke(_ d: CloudDevice) {
        let alert = NSAlert()
        alert.messageText = "Sign out \(d.name)?"
        alert.informativeText = "It stops syncing and keeps its notes. It can sign in again with your password."
        alert.addButton(withTitle: "Sign Out \(d.name)")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Task { await cloud.revoke(d.id) } }
    }
}
