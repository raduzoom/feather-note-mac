import SwiftUI

/// Settings › Advanced: the sync server (desktop-settings-advanced board).
struct AdvancedSettingsView: View {
    var cloud: CloudModel
    @State private var address = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Sync server").font(Theme.uiLabelStrong)
            TextField("Server address", text: $address, prompt: Text("https://notes.example.com"))
                .textFieldStyle(.roundedBorder)
                .disabled(cloud.state != .signedOut)
            Text("A self-hosted server may have different storage limits, and trial and plan details won't appear. Your notes are still encrypted on this device before upload.")
                .font(Theme.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if cloud.state != .signedOut {
                Text("Sign out to change the server.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
            ErrorLine(text: message)
            HStack(spacing: Spacing.s8) {
                Button(working ? "Connecting…" : "Connect to Server") {
                    working = true
                    Task { message = await cloud.connect(serverInput: address); working = false }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(address.isEmpty || working || cloud.state != .signedOut)
                Button("Use Feather Cloud") { cloud.useHostedServer(); address = ""; message = nil }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!cloud.isSelfHosted || cloud.state != .signedOut)
            }
        }
        .onAppear { address = cloud.isSelfHosted ? cloud.server.display : "" }
    }
}
