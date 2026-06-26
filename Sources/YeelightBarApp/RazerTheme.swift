import SwiftUI

// MARK: - Razer Synapse-inspired palette & components

extension Color {
    static let razerGreen     = Color(red: 0.267, green: 0.839, blue: 0.173)   // #44D62C signature
    static let razerGreenDim  = Color(red: 0.267, green: 0.839, blue: 0.173).opacity(0.55)
    static let razerBG        = Color(red: 0.086, green: 0.098, blue: 0.086)   // charcoal (not pure black)
    static let razerBGTop     = Color(red: 0.118, green: 0.133, blue: 0.118)   // lifted gradient top
    static let razerSurface   = Color(red: 0.137, green: 0.153, blue: 0.137)   // panel fill — pops vs bg
    static let razerSurfaceHi = Color(red: 0.184, green: 0.204, blue: 0.184)   // raised control fill
    static let razerText      = Color(white: 0.95)
    static let razerSecondary = Color(red: 0.64, green: 0.69, blue: 0.64)      // bright greenish-grey
    static let razerHairline  = Color.razerGreen.opacity(0.30)
}

/// Razer's angular panel geometry: a rect with the top-left and bottom-right corners sliced off.
struct ChamferedRectangle: Shape {
    var cut: CGFloat = 9
    func path(in r: CGRect) -> Path {
        let c = min(cut, min(r.width, r.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }
}

/// Full-bleed dark Razer backdrop: green top-glow + faint CRT scanlines.
struct RazerBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.razerBGTop, .razerBG], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.razerGreen.opacity(0.07), .clear],
                           center: .top, startRadius: 0, endRadius: 460)
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.black.opacity(0.16)), lineWidth: 0.5)
                    y += 3
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Razer panel: chamfered dark surface, thin neon hairline, UPPERCASE green caption.
struct RazerGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.system(size: 10.5, weight: .heavy))
                .textCase(.uppercase).tracking(1.6)
                .foregroundStyle(Color.razerGreen)
            configuration.content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.razerSurface)
        .clipShape(ChamferedRectangle(cut: 11))
        .overlay(ChamferedRectangle(cut: 11).stroke(Color.razerHairline, lineWidth: 1))
    }
}

/// Pulsing green glow for "live/active" elements.
struct RazerPulse: ViewModifier {
    var active: Bool
    var color: Color = .razerGreen
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .shadow(color: active ? color.opacity(on ? 0.85 : 0.2) : .clear, radius: active ? (on ? 11 : 4) : 0)
            .onAppear { pulse() }
            .onChange(of: active) { _ in pulse() }
    }
    private func pulse() {
        on = false
        guard active else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
    }
}

extension View {
    /// A section / hero heading in the Razer style: heavy, uppercase, tracked.
    func razerHeading(_ size: CGFloat = 13) -> some View {
        self.font(.system(size: size, weight: .heavy))
            .textCase(.uppercase).tracking(1.4)
            .foregroundStyle(Color.razerText)
    }

    /// HUD telemetry readout: monospaced green value in a bordered chip.
    func razerHUD() -> some View {
        self.font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.razerGreen)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.razerGreen.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.razerGreen.opacity(0.4), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    func razerPulse(_ active: Bool, color: Color = .razerGreen) -> some View { modifier(RazerPulse(active: active, color: color)) }

    /// Apply the whole Razer look (dark scheme, green accent, panel style) to a root view.
    func razerChrome() -> some View {
        self.preferredColorScheme(.dark)
            .tint(.razerGreen)
            .groupBoxStyle(RazerGroupBoxStyle())
    }
}
