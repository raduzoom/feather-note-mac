import SwiftUI

/// The window backdrop behind the glass columns: peach base with the blurred mint and peach glows of the board.
struct GlassBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bgWindow
                Ellipse()
                    .fill(Theme.glowMint)
                    .frame(width: 720, height: 624)
                    .position(x: 240, y: 152)
                    .blur(radius: 72)
                Circle()
                    .fill(Theme.glowPeach)
                    .frame(width: 560, height: 560)
                    .position(x: geo.size.width - 136, y: 400)
                    .blur(radius: 80)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
