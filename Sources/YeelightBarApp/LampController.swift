import SwiftUI
import AppKit
import CoreGraphics
import YeelightKit

enum SyncMode: Hashable { case off, screen, music }

/// Bridges SwiftUI to YeelightKit: device finding + live control.
@MainActor
final class LampController: ObservableObject {
    // Device finding
    @Published var devices: [DiscoveredDevice] = []
    @Published var selected: DiscoveredDevice?
    @Published var isSearching = false
    @Published var manualIP = ""

    // Live state of the connected lamp
    @Published var connected = false
    @Published var connecting = false
    @Published var connectError: String?
    @Published var screenSyncOn = false
    @Published var screenSyncStatus: String?
    @Published var musicSyncOn = false
    @Published var musicSyncStatus: String?
    @Published var syncColor = Color(rgb: 0x000000)
    @Published var captureInfo: String?
    @Published var screenHasPermission = false
    @Published var bandFraction: Double = 0.25 { didSet { sync.bandFraction = bandFraction } }
    @Published var brightnessFollow = false
    @Published var syncSmoothing: Double = 0.35 { didSet { sync.smoothing = syncSmoothing } }
    @Published var syncSaturation: Double = 1.25 { didSet { sync.saturation = syncSaturation } }
    @Published var musicSensitivity: Double = 4.0 { didSet { music.sensitivity = musicSensitivity } }
    @Published var musicStyle: MusicStyle = .beat { didSet { music.style = musicStyle } }
    @Published var syncRegions: [String: SyncRegion] = [:] { didSet { if screenSyncOn || musicSyncOn { restartSync() } } }
    @Published var power = false
    @Published var brightness = 50.0      // 1…100
    @Published var colorTempK = 4000.0    // 2700…6500
    @Published var ambientColor = Color(rgb: 0xE30DFF)
    @Published var ambientOn = true

    private var device: YeelightDevice?
    private var ambientWork: DispatchWorkItem?
    private var lastBrightSend = Date.distantPast
    private let sync = ScreenSyncEngine()
    private let music = MusicSyncEngine()
    private let savedIDKey = "selectedDeviceID"
    private let savedIPKey = "selectedDeviceIP"

    init() {
        sync.onState = { [weak self] running, err in self?.screenSyncOn = running; self?.screenSyncStatus = err }
        sync.onColor = { [weak self] rgb in self?.syncColor = Color(rgb: rgb) }
        sync.onSource = { [weak self] w, h in self?.captureInfo = "\(w)×\(h)" }
        sync.onLuma = { [weak self] luma in self?.applyLuma(luma) }
        sync.bandFraction = bandFraction
        sync.smoothing = syncSmoothing
        sync.saturation = syncSaturation
        music.onState = { [weak self] running, err in self?.musicSyncOn = running; self?.musicSyncStatus = err }
        music.onColor = { [weak self] rgb in self?.syncColor = Color(rgb: rgb) }
        music.sensitivity = musicSensitivity
        music.style = musicStyle
        refreshScreenPermission()
        restoreOnLaunch()
    }

    // MARK: - Finding

    /// On launch, reconnect to the lamp the user previously CHOSE — matched by stable id
    /// (fallback IP). Never guesses a device the user didn't pick.
    private func restoreOnLaunch() {
        let savedID = UserDefaults.standard.string(forKey: savedIDKey) ?? ""
        let savedIP = UserDefaults.standard.string(forKey: savedIPKey) ?? ""
        guard !savedID.isEmpty || !savedIP.isEmpty else { return } // first run → show the list
        isSearching = true
        Task.detached {
            let found = YeelightDiscovery.auto()
            await MainActor.run {
                self.devices = found
                self.isSearching = false
                let match = found.first(where: { !savedID.isEmpty && $0.id == savedID })
                         ?? found.first(where: { !savedIP.isEmpty && $0.ip == savedIP })
                if let match { self.connect(to: match) }
            }
        }
    }

    /// "Auto-search" button: find + LIST only. The user picks — no auto-connect.
    func autoSearch() {
        guard !isSearching else { return }
        isSearching = true
        Task.detached {
            let found = YeelightDiscovery.auto()
            await MainActor.run {
                self.devices = found
                self.isSearching = false
            }
        }
    }

    func addManualIP() {
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !isSearching else { return }
        isSearching = true
        Task.detached {
            let dev = YeelightDiscovery.validate(ip: ip)
            await MainActor.run {
                self.isSearching = false
                guard let dev else { return }
                if !self.devices.contains(where: { $0.ip == dev.ip }) { self.devices.append(dev) }
                self.manualIP = ""
                self.connect(to: dev) // manual add is an explicit choice
            }
        }
    }

    /// Blink a lamp so the user can see which physical device a row is.
    func identify(_ d: DiscoveredDevice) {
        let dev = YeelightDevice(ip: d.ip, tcpPort: d.port)
        Task.detached {
            _ = try? dev.control("start_cf", [6, 0, "300,2,3500,100,300,2,3500,1"])
        }
    }

    func connect(to d: DiscoveredDevice?) {
        guard let d else { return }
        stopScreenSync()
        stopMusicSync()
        selected = d
        if syncRegions[d.ip] == nil { syncRegions[d.ip] = .top }   // primary defaults to the top band
        device = YeelightDevice(ip: d.ip, tcpPort: d.port)
        if !d.id.isEmpty { UserDefaults.standard.set(d.id, forKey: savedIDKey) }
        UserDefaults.standard.set(d.ip, forKey: savedIPKey)
        connecting = true
        connectError = nil
        refresh()
    }

    func backToDevices() { connected = false }

    func refresh() {
        guard let device else { connecting = false; return }
        let ip = selected?.ip ?? ""
        Task.detached {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power"])) ?? []
            await MainActor.run {
                self.connecting = false
                guard props.count >= 4 else {
                    self.connected = false
                    self.connectError = "Лампа \(ip) не ответила (возможно, занята). Подожди пару секунд и нажми снова."
                    return
                }
                self.connected = true
                self.connectError = nil
                self.apply(props)
            }
        }
    }

    /// Background re-read after a discrete action — never disconnects on a transient miss.
    private func pollState() {
        guard let device, connected else { return }
        Task.detached {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power"])) ?? []
            await MainActor.run { if props.count >= 4 { self.apply(props) } }
        }
    }

    private func apply(_ props: [String]) {
        power = (props[0] == "on")
        brightness = Double(props[1]) ?? brightness
        colorTempK = Double(props[2]) ?? colorTempK
        if let rgb = Int(props[3]), rgb > 0 { ambientColor = Color(rgb: rgb) }
        if props.count > 4 { ambientOn = (props[4] == "on") }
    }

    // MARK: - Control (push current published value to the lamp)

    /// Master power for the whole device. This Screen Light Bar Pro ignores `set_power`
    /// for full power-off — `dev_toggle` is the only method that reliably toggles it.
    func togglePower() {
        let target = !power
        if !target { stopScreenSync(); stopMusicSync() }
        power = target
        push { try $0.control("dev_toggle", []) }
        scheduleResync()
    }

    /// Debounced ambient-colour push — coalesces ColorPicker drags so we never
    /// exceed the lamp's ~60 cmd/min TCP quota.
    func setAmbient(_ c: Color) {
        if screenSyncOn { stopScreenSync() }   // a static colour replaces live screen-sync
        ambientColor = c
        ambientOn = true
        ambientWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.push { try $0.control("bg_set_power", ["on", "smooth", 0]) } // ensure ambient is on
            self.pushAmbient()
        }
        ambientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func pushBrightness() { let v = Int(brightness); push { try $0.setBrightness(v) } }
    func pushColorTemp() { let k = Int(colorTempK); push { try $0.setColorTemp(k) } }
    func pushAmbient() { let rgb = ambientColor.rgbInt; push { try $0.setAmbientRGB(rgb) } }

    /// Independent on/off for the ambient (back) light only.
    func setAmbientPower(_ on: Bool) {
        if !on { stopScreenSync(); stopMusicSync() }   // backlight off → stop any running sync
        ambientOn = on
        let v = on ? "on" : "off"
        push { try $0.control("bg_set_power", [v, "smooth", 300]) }
    }

    func applyScene(ct: Int, bright: Int) {
        power = true
        colorTempK = Double(ct)
        brightness = Double(bright)
        // one atomic command sets CT + brightness together → identical every press
        push { try $0.control("set_scene", ["ct", ct, bright]) }
        scheduleResync()
    }

    private func push(_ op: @escaping (YeelightDevice) throws -> String) {
        guard let device else { return }
        Task.detached { _ = try? op(device) }
    }

    // MARK: - Screen sync (ambilight)

    func toggleScreenSync() {
        if screenSyncOn { stopScreenSync(); return }   // sync off — ambient stays as a static colour
        guard selected != nil, connected else {
            screenSyncStatus = "Сначала подключись к лампе."
            return
        }
        stopMusicSync()              // screen-sync and music-sync are mutually exclusive
        ambientOn = true             // sync turns the backlight on — reflect it in the toggle
        screenSyncOn = true            // optimistic; reverted by onState on failure
        screenSyncStatus = "Запуск…"
        push { try $0.control("bg_set_power", ["on", "smooth", 200]) } // ensure ambient is on
        sync.start(targets: syncTargets())
    }

    func stopScreenSync() {
        let wasOn = screenSyncOn
        sync.stop()
        screenSyncOn = false
        screenSyncStatus = nil
        if wasOn { ambientColor = syncColor; ambientOn = true }   // keep last live colour as static ambient
    }

    // MARK: - Music sync

    func toggleMusicSync() {
        if musicSyncOn { stopMusicSync(); return }
        guard selected != nil, connected else {
            musicSyncStatus = "Сначала подключись к лампе."
            return
        }
        stopScreenSync()             // mutually exclusive with screen-sync
        ambientOn = true             // sync turns the backlight on — reflect it in the toggle
        musicSyncOn = true
        musicSyncStatus = "Запуск…"
        push { try $0.control("bg_set_power", ["on", "smooth", 200]) } // ensure ambient is on
        music.start(targets: syncTargets())
    }

    func stopMusicSync() {
        let wasOn = musicSyncOn
        music.stop()
        musicSyncOn = false
        musicSyncStatus = nil
        if wasOn { ambientColor = syncColor; ambientOn = true }
    }

    // MARK: - Multi-device sync targets (each lamp samples its own screen region)

    private func syncTargets() -> [SyncTarget] {
        devices.compactMap { d in
            guard let region = syncRegions[d.ip] else { return nil }
            return SyncTarget(ip: d.ip, port: d.port, method: streamMethod(for: d), region: region)
        }
    }

    func setRegion(_ ip: String, _ region: SyncRegion?) {
        if let region { syncRegions[ip] = region } else { syncRegions.removeValue(forKey: ip) }
    }

    /// bg-capable lamps stream the ambient channel; plain RGB strips stream the main channel.
    private func streamMethod(for d: DiscoveredDevice) -> String {
        d.support.contains("bg_set_rgb") ? "bg_set_rgb" : "set_rgb"
    }

    private func restartSync() {
        let targets = syncTargets()
        if screenSyncOn { sync.stop(); sync.start(targets: targets) }
        if musicSyncOn { music.stop(); music.start(targets: targets) }
    }

    // MARK: - Effect mode (single off / screen / music selector)

    var syncMode: SyncMode { screenSyncOn ? .screen : (musicSyncOn ? .music : .off) }

    func setSyncMode(_ mode: SyncMode) {
        switch mode {
        case .off:
            if screenSyncOn { toggleScreenSync() }
            if musicSyncOn { toggleMusicSync() }
        case .screen:
            if musicSyncOn { stopMusicSync() }
            if !screenSyncOn { toggleScreenSync() }
        case .music:
            if screenSyncOn { stopScreenSync() }
            if !musicSyncOn { toggleMusicSync() }
        }
    }

    func refreshScreenPermission() {
        screenHasPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenSettings() {
        CGRequestScreenCaptureAccess() // surfaces the system prompt the first time
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Brightness-follow: front bar tracks scene luminance, throttled to stay under the TCP quota.
    private func applyLuma(_ luma: Double) {
        guard brightnessFollow, connected else { return }
        let target = Int(15 + luma * 85)               // 15…100%
        let now = Date()
        guard now.timeIntervalSince(lastBrightSend) > 1.2,
              abs(Double(target) - brightness) > 4 else { return }
        lastBrightSend = now
        brightness = Double(target)
        push { try $0.setBrightness(target) }
    }

    /// Re-read lamp state shortly after a discrete action (e.g. power) so the UI
    /// reflects reality even if the command silently failed.
    private func scheduleResync() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollState() }
    }
}

// MARK: - Color <-> 0xRRGGBB

extension Color {
    init(rgb: Int) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    var rgbInt: Int {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (Int(c.redComponent * 255) << 16)
             | (Int(c.greenComponent * 255) << 8)
             |  Int(c.blueComponent * 255)
    }
}
