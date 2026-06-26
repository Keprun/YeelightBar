import SwiftUI

// MARK: - Razer Synapse-inspired palette & components

extension Color {
    static let razerGreen     = Color(red: 0.267, green: 0.839, blue: 0.173)   // #44D62C signature
    static let razerGreenDim  = Color(red: 0.267, green: 0.839, blue: 0.173).opacity(0.55)
    static let razerBG        = Color(red: 0.086, green: 0.098, blue: 0.086)   // ~#16191 6 charcoal (not pure black)
    static let razerBGTop     = Color(red: 0.118, green: 0.133, blue: 0.118)   // lifted gradient top
    static let razerSurface   = Color(red: 0.137, green: 0.153, blue: 0.137)   // panel fill (#23272 3) — pops vs bg
    static let razerSurfaceHi = Color(red: 0.184, green: 0.204, blue: 0.184)   // raised control fill
    static let razerText      = Color(white: 0.95)
    static let razerSecondary = Color(red: 0.64, green: 0.69, blue: 0.64)      // bright greenish-grey (readable)
    static let razerHairline  = Color.razerGreen.opacity(0.30)
}

/// Full-bleed dark Razer backdrop with a faint green glow up top.
struct RazerBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.razerBGTop, .razerBG], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.razerGreen.opacity(0.06), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// Razer panel: dark surface, sharp corners, thin neon hairline, UPPERCASE green caption.
struct RazerGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.system(size: 10.5, weight: .heavy))
                .textCase(.uppercase)
                .tracking(1.6)
                .foregroundStyle(Color.razerGreen)
            configuration.content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.razerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.razerHairline, lineWidth: 1)
        )
    }
}

extension View {
    /// A section / hero heading in the Razer style: heavy, uppercase, tracked.
    func razerHeading(_ size: CGFloat = 13) -> some View {
        self.font(.system(size: size, weight: .heavy))
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Color.razerText)
    }

    /// Apply the whole Razer look (dark scheme, green accent, panel style) to a root view.
    func razerChrome() -> some View {
        self.preferredColorScheme(.dark)
            .tint(.razerGreen)
            .groupBoxStyle(RazerGroupBoxStyle())
    }
}
