import FeatherSync
import Foundation

/// The sidebar footer's lines (ui-copy.md "Sync status lines", desktop-sync-status board).
struct SyncStatusText: Equatable {
    var title: String
    var detail: String?
    var action: String?

    /// The one line under the email in Settings › Sync.
    var settingsLine: String { [title, detail].compactMap { $0 }.joined(separator: " ") }

    static func make(state: CloudState, status: SyncStatus, plan: CloudPlan?, selfHostedHost: String?, reauthEmail: String? = nil,
                     now: Date) -> SyncStatusText {
        if state == .signedOut, reauthEmail != nil {
            return SyncStatusText(title: "Signed out of Feather Cloud", detail: "Sign in again to keep syncing.", action: "Sign In…")
        }
        guard state != .signedOut else { return SyncStatusText(title: "Sync with Feather Cloud") }
        if plan?.state == "read_only" || status == .readOnly {
            return SyncStatusText(title: "Read-only sync", detail: "Notes still arrive. Changes here stay on this Mac.")
        }
        switch status {
        case .syncing(let done, let total):
            return SyncStatusText(title: "Syncing… \(done) of \(total)")
        case .offline:
            return SyncStatusText(title: "Offline", detail: "Changes sync when you're back online.")
        case .error(let reason):
            return SyncStatusText(title: "Couldn't sync", detail: reason, action: "Try Again")
        case .quotaFull:
            return SyncStatusText(title: "Storage full", detail: "New changes stay on this Mac.")
        case .signedOut:
            return SyncStatusText(title: "Sync with Feather Cloud")
        case .readOnly, .idle:
            break
        }
        var last: Date?
        if case .idle(let d) = status { last = d }
        let ago = last.map { CloudFormat.ago($0, now: now) }
        if let host = selfHostedHost {
            return SyncStatusText(title: host, detail: ago.map { "Synced \($0)" })
        }
        if let plan, plan.state == "trial", let ends = plan.trialEndsAt {
            let days = max(0, Int(ceil(ends.timeIntervalSince(now) / 86_400)))
            var detail = "\(CloudFormat.size(plan.usedBytes)) of \(CloudFormat.size(plan.quotaBytes))"
            if let ago { detail += " · synced \(ago)" }
            return SyncStatusText(title: "Trial: \(days) \(days == 1 ? "day" : "days") left", detail: detail)
        }
        return SyncStatusText(title: "Synced", detail: ago)
    }

    init(title: String, detail: String? = nil, action: String? = nil) {
        self.title = title
        self.detail = detail
        self.action = action
    }
}

/// The banner above the note list for Feather Cloud states (ui-copy.md "Feather Cloud states").
enum CloudBanner: Equatable {
    case readOnly
    case trialEnding(days: Int)
    case storageNearlyFull(used: Int64, quota: Int64)
    case storageFull

    var text: String {
        switch self {
        case .readOnly:
            "Your Feather Cloud subscription has ended. Your notes are safe on this device and still arrive from your other devices, but changes made here won't upload until you subscribe. Nothing has been deleted."
        case .trialEnding(let days):
            "Your Feather Cloud trial ends in \(days) \(days == 1 ? "day" : "days"). Subscribe to keep syncing; your notes stay on this Mac either way."
        case .storageNearlyFull(let used, let quota):
            "Your Feather Cloud storage is 90% full: \(CloudFormat.size(used)) of \(CloudFormat.size(quota))."
        case .storageFull:
            "Your Feather Cloud storage is full. New changes stay on this device until you free up space."
        }
    }

    /// Self-hosted servers show none of these: their plans and limits are the owner's.
    static func make(status: SyncStatus, plan: CloudPlan?, selfHosted: Bool, now: Date) -> CloudBanner? {
        guard !selfHosted else { return nil }
        if status == .readOnly || plan?.state == "read_only" { return .readOnly }
        if status == .quotaFull { return .storageFull }
        guard let plan else { return nil }
        if plan.quotaBytes > 0, plan.usedBytes * 10 >= plan.quotaBytes * 9 { return .storageNearlyFull(used: plan.usedBytes, quota: plan.quotaBytes) }
        if plan.state == "trial", let ends = plan.trialEndsAt {
            let days = Int(ceil(ends.timeIntervalSince(now) / 86_400))
            if days <= 3 { return .trialEnding(days: max(0, days)) }
        }
        return nil
    }
}
