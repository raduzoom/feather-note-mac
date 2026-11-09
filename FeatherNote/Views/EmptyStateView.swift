import SwiftUI

/// A designed empty state: title, message, at most one primary action and one secondary.
struct EmptyStateView: View {
    let title: String
    let message: String
    var primary: (label: String, action: () -> Void)?
    var secondary: (label: String, action: () -> Void)?
    var footnote: String?

    var body: some View {
        VStack(spacing: Spacing.s16) {
            Text(title)
                .font(Theme.panelTitle)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.uiLabel)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if primary != nil || secondary != nil {
                HStack(spacing: Spacing.s8) {
                    if let primary { Button(primary.label, action: primary.action).buttonStyle(PrimaryButtonStyle()) }
                    if let secondary { Button(secondary.label, action: secondary.action).buttonStyle(SecondaryButtonStyle()) }
                }
                .padding(.top, Spacing.s8)
            }
            if let footnote {
                Text(footnote).font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Spacing.s64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
