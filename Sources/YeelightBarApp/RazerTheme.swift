import SwiftUI

// MARK: - Razer Synapse-inspired palette & components

extension Color {
    static let razerGreen     = Color(red: 0.267, green: 0.839, blue: 0.173)   // #44D62C signature
    static let razerGreenDim  = Color(red: 0.267, green: 0.839, blue: 0.173).opacity(0.55)
    static let razerBG        = Color(red: 0.039, green: 0.047, blue: 0.039)   // ~#0A0C0A near-black
    static let razerBGTop     = Color(red: 0.063, green: 0.078, blue: 0.063)   // slightly lifted (gradient top)
    static let razerSurface   = Color(red: 0.082, green: 0.094, blue: 0.082)   // panel fill
    static let razerSurfaceHi = Color(red: 0.114, green: 0.129, blue: 0.114)   // raised control fill
    static let razerText      = Color(white: 0.93)
    static let razerSecondary = Color(red: 0.46, green: 0.51, blue: 0.46)      // greenish-grey
    static let razerHairline  = Color.razerGreen.opacity(0.22)
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
