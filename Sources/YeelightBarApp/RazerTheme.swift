import SwiftUI
import AppKit

// MARK: - Gamer-brand themes (Razer / Asus ROG / Asus TUF / Gigabyte Aorus)
// Each palette has a Light AND Dark value per colour, so every theme adapts to the macOS
// appearance (incl. the time-of-day "Auto" switch) — dark at night, light by day.

/// A colour with separate Light and Dark values — follows the system appearance.
private func dyn(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = isDark ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}

/// One brand's full palette. `accent` is the signature colour; the rest is the chrome.
struct ThemePalette {
    let accent, bg, bgTop, surface, surfaceHi, text, secondary: Color
}

enum AppTheme: String, CaseIterable, Identifiable {
    case venom, crimson, forge, solar
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .venom:   return "Venom"
        case .crimson: return "Crimson"
        case .forge:   return "Forge"
        case .solar:   return "Solar"
        }
    }
    var swatch: Color { palette.accent }
    var palette: ThemePalette {
        switch self {
        case .venom:    // toxic neon green on a deep green-black chrome
            return ThemePalette(
                accent:     dyn((0.10, 0.52, 0.05), (0.30, 0.95, 0.25)),
                bg:         dyn((0.93, 0.965, 0.92), (0.039, 0.075, 0.043)),
                bgTop:      dyn((0.975, 0.995, 0.965), (0.060, 0.110, 0.066)),
                surface:    dyn((1.0, 1.0, 0.985), (0.071, 0.125, 0.078)),
                surfaceHi:  dyn((0.89, 0.93, 0.875), (0.105, 0.175, 0.110)),
                text:       dyn((0.08, 0.14, 0.07), (0.90, 0.98, 0.90)),
                secondary:  dyn((0.33, 0.45, 0.32), (0.56, 0.73, 0.55)))
        case .crimson:  // blood red on a deep red-black chrome
            return ThemePalette(
                accent:     dyn((0.78, 0.0, 0.12), (1.0, 0.22, 0.30)),
                bg:         dyn((0.975, 0.93, 0.94), (0.090, 0.035, 0.046)),
                bgTop:      dyn((0.99, 0.955, 0.965), (0.130, 0.052, 0.066)),
                surface:    dyn((1.0, 0.985, 0.99), (0.145, 0.060, 0.075)),
                surfaceHi:  dyn((0.94, 0.885, 0.90), (0.205, 0.090, 0.110)),
                text:       dyn((0.14, 0.07, 0.085), (0.98, 0.91, 0.92)),
                secondary:  dyn((0.45, 0.34, 0.36), (0.74, 0.57, 0.60)))
        case .forge:    // molten amber on a deep warm-black chrome
            return ThemePalette(
                accent:     dyn((0.60, 0.43, 0.0), (1.0, 0.74, 0.13)),
                bg:         dyn((0.975, 0.955, 0.90), (0.086, 0.066, 0.026)),
                bgTop:      dyn((0.995, 0.985, 0.945), (0.122, 0.097, 0.042)),
                surface:    dyn((1.0, 0.995, 0.955), (0.135, 0.108, 0.050)),
                surfaceHi:  dyn((0.93, 0.91, 0.85), (0.195, 0.158, 0.072)),
                text:       dyn((0.14, 0.11, 0.05), (0.98, 0.95, 0.87)),
                secondary:  dyn((0.45, 0.40, 0.29), (0.74, 0.68, 0.52)))
        case .solar:    // orange flare on a deep orange-black chrome
            return ThemePalette(
                accent:     dyn((0.82, 0.34, 0.0), (1.0, 0.50, 0.12)),
                bg:         dyn((0.98, 0.95, 0.91), (0.098, 0.052, 0.022)),
                bgTop:      dyn((0.995, 0.975, 0.93), (0.138, 0.078, 0.032)),
                surface:    dyn((1.0, 0.99, 0.945), (0.152, 0.088, 0.038)),
                surfaceHi:  dyn((0.94, 0.90, 0.84), (0.215, 0.125, 0.055)),
                text:       dyn((0.14, 0.10, 0.05), (0.98, 0.93, 0.87)),
                secondary:  dyn((0.46, 0.39, 0.30), (0.75, 0.64, 0.53)))
        }
    }
}

/// In-app light/dark override (independent of the macOS day/night switch). `auto` = follow the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

/// Holds the selected theme + appearance (persisted). Views observe it so changes apply app-wide live.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @Published var theme: AppTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") } }
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance"); applyAppearance() }
    }
    private init() {
        let raw = UserDefaults.standard.string(forKey: "appTheme") ?? ""
        let migrate = ["razer": "venom", "rog": "crimson", "tuf": "forge", "aorus": "solar"]   // old brand keys → new
        theme = AppTheme(rawValue: migrate[raw] ?? raw) ?? .venom
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "") ?? .auto
    }
    /// Force the whole app's appearance (nil = follow macOS). Drives both the dyn() colours and SwiftUI's colorScheme.
    func applyAppearance() { NSApplication.shared.appearance = appearance.nsAppearance }
}

/// The colour API used across the app. Names are historical ("razer*"); each now resolves to the
/// SELECTED theme's palette, still dynamic for day/night.
extension Color {
    private static var pal: ThemePalette { ThemeManager.shared.theme.palette }
    static var razerGreen: Color     { pal.accent }
    static var razerBG: Color        { pal.bg }
    static var razerBGTop: Color     { pal.bgTop }
    static var razerSurface: Color   { pal.surface }
    static var razerSurfaceHi: Color { pal.surfaceHi }
    static var razerText: Color      { pal.text }
    static var razerSecondary: Color { pal.secondary }
    static var razerGreenDim: Color  { pal.accent.opacity(0.55) }
    static var razerHairline: Color  { pal.accent.opacity(0.30) }
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
        let dark = scheme == .dark
        ZStack {
            LinearGradient(colors: [.razerBGTop, .razerBG], startPoint: .top, endPoint: .bottom)
            // two accent auras (theme-coloured) for depth — a strong top-left glow + a soft bottom-right one
            RadialGradient(colors: [Color.razerGreen.opacity(dark ? 0.18 : 0.06), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 540)
            RadialGradient(colors: [Color.razerGreen.opacity(dark ? 0.10 : 0.03), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 480)
            Canvas { ctx, size in
                let op = dark ? 0.16 : 0.05
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

/// Animated "⚡ YEELIGHT BAR" wordmark: the bolt flickers like lightning (a sharp double-flash with a
/// white-hot peak + glow burst), and a sheen sweeps across the letters. One TimelineView clock drives
/// it all, so it only animates while the window is actually on screen.
struct AnimatedWordmark: View {
    var active: Bool                 // connected → full strikes; offline → a calm dim glow
    var boltSize: CGFloat = 12
    var textSize: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let s = Self.strike(t, active: active)          // 0 = rest, 1 = peak of a lightning flash
            HStack(spacing: 8) {
                bolt(s)
                wordmark.overlay { sheen(t).mask(wordmark) } // moving highlight, clipped to the glyphs
            }
        }
    }

    /// The static logotype — reused as both the visible text and the sheen mask.
    private var wordmark: some View {
        HStack(spacing: 8) {
            Text("YEELIGHT").foregroundStyle(Color.razerText)
            Text("BAR").foregroundStyle(Color.razerGreen)
        }
        .font(.system(size: textSize, weight: .heavy)).tracking(2.5)
    }

    private func bolt(_ s: Double) -> some View {
        ZStack {
            Image(systemName: "bolt.fill").foregroundStyle(Color.razerGreen)
            Image(systemName: "bolt.fill").foregroundStyle(.white).opacity(s)   // white-hot at the flash
        }
        .font(.system(size: boltSize, weight: .black))
        .scaleEffect(1 + 0.16 * s)
        .shadow(color: Color.razerGreen.opacity(0.25 + 0.70 * s), radius: 3 + 12 * s)
    }

    private func sheen(_ t: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let period = 3.4
            let p = t.truncatingRemainder(dividingBy: period) / period          // 0..1 sweep cycle
            LinearGradient(colors: [.clear, .white.opacity(active ? 0.85 : 0.30), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 0.4)
                .offset(x: -w * 0.5 + p * (w * 1.5))                             // travel off-left → off-right
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    /// Lightning intensity at time `t`: a sharp double-flash near the top of each cycle, a gentle
    /// shimmer in between. Offline → just a slow dim breath, no strikes.
    private static func strike(_ t: Double, active: Bool) -> Double {
        guard active else { return 0.10 + 0.10 * (0.5 + 0.5 * sin(t * 1.4)) }
        let ph = t.truncatingRemainder(dividingBy: 3.2)
        if ph < 0.06 { return 1.0 }
        if ph < 0.12 { return 0.45 }
        if ph < 0.18 { return 0.92 }                                            // second flicker
        if ph < 0.26 { return 0.30 }
        return 0.16 + 0.10 * (0.5 + 0.5 * sin(t * 3))                           // resting shimmer
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
