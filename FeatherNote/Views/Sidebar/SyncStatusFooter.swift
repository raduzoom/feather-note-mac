import SwiftUI

/// Sync status at the foot of the sidebar (desktop-sync-status board). Signed out, it invites the free trial.
struct SyncStatusFooter: View {
    var cloud: CloudModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let text = SyncStatusText.make(state: cloud.state, status: cloud.status, plan: cloud.plan,
                                           selfHostedHost: cloud.isSelfHosted ? cloud.server.host : nil, reauthEmail: cloud.reauthEmail,
                                           now: context.date)
            HStack(alignment: .center, spacing: Spacing.s8) {
                Image(systemName: icon).foregroundStyle(iconColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.title).font(Theme.uiLabelStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let detail = text.detail {
                        Text(detail).font(Theme.meta).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let action = text.action {
                    Button(action) { cloud.state == .signedOut ? cloud.showSignIn() : cloud.syncNow() }.buttonStyle(.link).font(Theme.meta)
                }
            }
            .padding(.horizontal, Spacing.s16)
            .padding(.vertical, Spacing.s8)
            .contentShape(Rectangle())
            .onTapGesture {
                guard cloud.state == .signedOut else { return }
                if cloud.reauthEmail != nil || cloud.isSelfHosted { cloud.showSignIn() } else { cloud.startTrial() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(cloud.state == .signedOut ? .isButton : [])
        }
    }

    private var icon: String {
        guard cloud.state != .signedOut else { return "icloud" }
        switch cloud.status {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "icloud.slash"
        case .error, .quotaFull: return "exclamationmark.icloud"
        case .readOnly: return "lock.icloud"
        default: return "checkmark.icloud"
        }
    }

    private var iconColor: Color {
        switch cloud.status {
        case .error, .quotaFull: Theme.warningIcon
        default: Theme.accent
        }
    }
}

/// A Feather Cloud banner over the note list (read-only, trial ending, storage).
struct CloudBannerView: View {
    var banner: CloudBanner

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warningIcon).accessibilityHidden(true)
            Text(banner.text).font(Theme.meta).foregroundStyle(Theme.warningText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBanner)
    }
}
