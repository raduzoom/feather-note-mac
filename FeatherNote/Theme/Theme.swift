import AppKit
import SwiftUI

/// Design tokens from universal/design/tokens.json (direction D · Mint Glass).
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    static let bgWindow = dynamic(hex(0xF1E2D5), hex(0x11171D))
    static let glowMint = dynamic(hex(0xCFE7D9), hex(0x1C4A3A))
    static let glowPeach = dynamic(hex(0xF7CDB4), hex(0x4A2E26))
    static let glassList = dynamic(rgba(255, 240, 230, 0.50), rgba(48, 36, 34, 0.50))
    static let glassEditor = dynamic(rgba(240, 248, 243, 0.62), rgba(24, 38, 34, 0.60))
    static let surfaceRaised = dynamic(rgba(255, 255, 255, 0.80), rgba(255, 255, 255, 0.10))
    static let hairline = dynamic(rgba(19, 36, 58, 0.08), rgba(255, 255, 255, 0.08))
    static let textPrimary = dynamic(hex(0x13243A), hex(0xECF2EE))
    static let textBody = dynamic(hex(0x1C2B3E), hex(0xDDE6E1))
    static let textSecondary = dynamic(hex(0x3E4C5A), hex(0xA4B1BC))
    static let textPlaceholder = dynamic(hex(0x6E7B88), hex(0x8C99A4))
    static let accent = dynamic(hex(0x1F7A55), hex(0x6FD3A3))
    static let accentTint = dynamic(rgba(31, 122, 85, 0.12), rgba(111, 211, 163, 0.16))
    static let accentOnTint = dynamic(hex(0x16603F), hex(0x94E2BC))
    static let actionPrimary = dynamic(hex(0x13243A), hex(0xD3EEDF))
    static let onPrimary = dynamic(hex(0xFFFFFF), hex(0x13243A))
    static let actionPrimaryHover = dynamic(hex(0x24384F), hex(0xE2F5EA))
    static let actionPrimaryPressed = dynamic(hex(0x0B1726), hex(0xC0E3D0))
    static let actionDisabled = dynamic(hex(0xCBD2D9), rgba(255, 255, 255, 0.12))
    static let onDisabled = dynamic(hex(0x5B6672), hex(0x8C99A4))
    static let actionOutline = dynamic(rgba(19, 36, 58, 0.30), rgba(255, 255, 255, 0.30))
    static let warningText = dynamic(hex(0x6E4200), hex(0xF7C77D))
    static let warningIcon = dynamic(hex(0x8A5300), hex(0xF2B45A))
    static let warningBanner = dynamic(rgba(255, 247, 232, 0.90), rgba(110, 66, 0, 0.35))
    static let dangerText = dynamic(hex(0x8A1C12), hex(0xFFB4AB))
    static let searchMatch = dynamic(rgba(245, 180, 70, 0.42), rgba(245, 180, 70, 0.35))

    // NSColor versions for the AppKit text view.
    static let textBodyNS = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xDDE6E1) : hex(0x1C2B3E) }
    static let accentNS = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x6FD3A3) : hex(0x1F7A55) }

    // Type (tokens "type.*", desktop sizes)
    static let noteTitle = Font.system(size: 44, weight: .bold, design: .serif)
    static let panelTitle = Font.system(size: 28, weight: .semibold, design: .serif)
    static let listTitle = Font.system(size: 15, weight: .semibold, design: .serif)
    static let uiLabel = Font.system(size: 13)
    static let uiLabelStrong = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 12)
    static let overline = Font.system(size: 11, weight: .semibold)

    static func bodyNSFont(size: CGFloat = 16) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static func titleNSFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: 44, weight: .bold)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 44) } ?? base
    }
}

/// The 8pt grid (tokens "spacing.scale").
enum Spacing {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s40: CGFloat = 40
    static let s48: CGFloat = 48
    static let s64: CGFloat = 64
}

/// The one filled navy button per screen (component-inventory "Button").
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, isEnabled: isEnabled)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.uiLabelStrong)
                .foregroundStyle(isEnabled ? Theme.onPrimary : Theme.onDisabled)
                .padding(.horizontal, Spacing.s16)
                .frame(height: 32)
                .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }

        private var fill: Color {
            if !isEnabled { return Theme.actionDisabled }
            if configuration.isPressed { return Theme.actionPrimaryPressed }
            return hovering ? Theme.actionPrimaryHover : Theme.actionPrimary
        }
    }
}

/// Secondary: outlined, transparent (component-inventory "Button").
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.uiLabelStrong)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Spacing.s16)
            .frame(height: 32)
            .background(configuration.isPressed ? Theme.hairline : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.actionOutline, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}
