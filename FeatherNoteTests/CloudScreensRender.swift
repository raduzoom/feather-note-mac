import AppKit
import FeatherCore
import FeatherCrypto
import FeatherSync
import SwiftUI
import Testing
@testable import FeatherNote

/// Renders the Feather Cloud screens to PNGs for comparison with the boards, when FEATHER_SHOT_DIR is set
/// (TEST_RUNNER_FEATHER_SHOT_DIR through xcodebuild).
@MainActor @Suite struct CloudScreensRender {
    var dir: URL? { ProcessInfo.processInfo.environment["FEATHER_SHOT_DIR"].map { URL(fileURLWithPath: $0) } }

    func shot<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false) throws {
        guard let dir else { return }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "\(name).png"))
    }

    @Test func renderCloudScreens() async throws {
        guard dir != nil else { return }
        let m = try await makeModel()
        let flow = OnboardingFlow(cloud: m.cloud)
        let sheet = CGSize(width: 520, height: 520)
        try shot("onboarding-1", OnboardingSheet(flow: flow, close: {}, signIn: {}), size: sheet)
        flow.step = 2; flow.email = "alex@example.com"; flow.password = "a few random words here"
        try shot("onboarding-2", OnboardingSheet(flow: flow, close: {}, signIn: {}), size: sheet)
        flow.step = 3; flow.code = "123456"
        try shot("onboarding-3", OnboardingSheet(flow: flow, close: {}, signIn: {}), size: sheet)
        flow.showRecoveryKey(RecoveryKey.generate())
        try shot("onboarding-4", OnboardingSheet(flow: flow, close: {}, signIn: {}), size: sheet)
        flow.step = 5
        try shot("onboarding-5", OnboardingSheet(flow: flow, close: {}, signIn: {}), size: sheet)
        let signIn = SignInFlow(cloud: m.cloud)
        signIn.email = "alex@example.com"
        try shot("signin-password", SignInSheet(flow: signIn, close: {}), size: sheet)
        signIn.mode = .recoveryKey
        try shot("signin-recovery", SignInSheet(flow: signIn, close: {}), size: sheet)
        signIn.mode = .newPassword
        signIn.newPassword = "a brand new password"
        try shot("signin-new-password", SignInSheet(flow: signIn, close: {}), size: sheet)
        try shot("settings-sync-signed-out", SyncSettingsView(model: m).padding(32), size: CGSize(width: 600, height: 360))
        try shot("settings-advanced", AdvancedSettingsView(cloud: m.cloud).padding(32), size: CGSize(width: 600, height: 300))
        try shot("footer-local", SyncStatusFooter(cloud: m.cloud), size: CGSize(width: 240, height: 56))
        try shot("banner-read-only", CloudBannerView(banner: .readOnly), size: CGSize(width: 360, height: 110))
        try shot("onboarding-2-dark", OnboardingSheet(flow: { let f = OnboardingFlow(cloud: m.cloud); f.step = 2; return f }(), close: {}, signIn: {}),
                 size: sheet, dark: true)
    }
}
