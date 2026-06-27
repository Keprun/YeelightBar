import SwiftUI
import AppKit

// MARK: - Razer Synapse-inspired palette & components (adapts to macOS Light / Dark / Auto)

/// A colour with separate Light and Dark values — follows the system appearance (incl. the
/// time-of-day "Auto" switch), so the app goes dark at night and light by day.
private func dyn(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = isDark ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}

extension Color {
    // signature green — bright on dark, a deeper readable green on light surfaces
    static let razerGreen     = dyn((0.16, 0.62, 0.09), (0.267, 0.839, 0.173))
    static let razerBG        = dyn((0.945, 0.955, 0.935), (0.086, 0.098, 0.086))
    static let razerBGTop     = dyn((0.985, 0.99, 0.975), (0.118, 0.133, 0.118))
    static let razerSurface   = dyn((1.0, 1.0, 0.995),   (0.137, 0.153, 0.137))
    static let razerSurfaceHi = dyn((0.90, 0.92, 0.89),  (0.184, 0.204, 0.184))
    static let razerText      = dyn((0.10, 0.12, 0.10),  (0.95, 0.95, 0.95))
    static let razerSecondary = dyn((0.36, 0.42, 0.35),  (0.64, 0.69, 0.64))
    static let razerGreenDim  = Color.razerGreen.opacity(0.55)
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

/// Dark/light Razer backdrop: green top-glow + faint scanlines (much subtler in light mode).
struct RazerBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors: [.razerBGTop, .razerBG], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.razerGreen.opacity(scheme == .dark ? 0.08 : 0.05), .clear],
                           center: .top, startRadius: 0, endRadius: 460)
            Canvas { ctx, size in
                let op = scheme == .dark ? 0.16 : 0.05
                var y: CGFloat = 0
                while y < size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.black.opacity(op)), lineWidth: 0.5)
                    y += 3
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Razer panel: chamfered surface, thin neon hairline, UPPERCASE green caption.
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

    /// Apply the Razer look — green accent + panel style. Follows the system Light/Dark/Auto theme.
    func razerChrome() -> some View {
        self.tint(.razerGreen).groupBoxStyle(RazerGroupBoxStyle())
    }
}
