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
    @Published var regionColors: [SyncRegion: Color] = [:]   // live colour sampled per screen zone
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
    private var pollTimer: Timer?
    private var pollMisses = 0
    private var pollEpoch = 0
    private let sync = ScreenSyncEngine()
    private let music = MusicSyncEngine()
    private let savedIDKey = "selectedDeviceID"
    private let savedIPKey = "selectedDeviceIP"

    init() {
        sync.onState = { [weak self] running, err in self?.screenSyncOn = running; self?.screenSyncStatus = err }
        sync.onColor = { [weak self] rgb in self?.syncColor = Color(rgb: rgb) }
        sync.onRegionColors = { [weak self] d in self?.regionColors = d.mapValues { Color(rgb: $0) } }
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
                guard let dev else {
                    self.connectError = "Не найдено устройство Yeelight по адресу \(ip)."
                    return
                }
                if !self.devices.contains(where: { $0.ip == dev.ip }) { self.devices.append(dev) }
                self.manualIP = ""
                self.connect(to: dev) // manual add is an explicit choice
            }
        }
    }

    /// Blink a lamp so the user can spot which physical device a row is. Uses `set_scene "cf"`,
    /// which turns the lamp ON into a colour flow even when it is currently off (plain `start_cf`
    /// does nothing on an off lamp), then restores the prior power state.
    func identify(_ d: DiscoveredDevice) {
        let isBar = d.support.contains("bg_set_rgb") || d.model == "lamp15"
        let flow = isBar
            ? "400,2,4000,100,400,2,4000,1,400,2,4000,100,400,2,4000,1"               // bar: warm-white CT blink
            : "400,1,16711680,100,400,1,255,100,400,1,16711680,100,400,1,255,100"     // strip/bulb: red/blue RGB blink
        let dev = YeelightDevice(ip: d.ip, tcpPort: d.port)
        Task.detached {
            let wasOn = ((try? dev.properties(["power"]))?.first == "on")
            _ = try? dev.control("set_scene", ["cf", 8, 0, flow])
            try? await Task.sleep(nanoseconds: 3_600_000_000)   // let the ~3.2 s flow finish
            _ = try? dev.power(wasOn)                            // restore the prior power state
        }
    }

    func connect(to d: DiscoveredDevice?) {
        guard let d else { return }
        stopScreenSync()
        stopMusicSync()
        pollTimer?.invalidate(); pollTimer = nil
        selected = d
        device = YeelightDevice(ip: d.ip, tcpPort: d.port)
        if !d.id.isEmpty { UserDefaults.standard.set(d.id, forKey: savedIDKey) }
        UserDefaults.standard.set(d.ip, forKey: savedIPKey)
        connecting = true
        connected = false        // drop stale state until the new lamp's props arrive
        connectError = nil
        refresh()
    }

    func backToDevices() { pollTimer?.invalidate(); pollTimer = nil; connected = false }

    func refresh() {
        guard let device else { connecting = false; return }
        let ip = selected?.ip ?? ""
        Task.detached {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power", "rgb", "main_power"])) ?? []
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
                self.startPollTimer()
            }
        }
    }

    /// Background re-read after a discrete action — never disconnects on a transient miss.
    private func pollState() {
        guard let device, connected else { return }
        Task.detached {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power", "rgb", "main_power"])) ?? []
            await MainActor.run { if props.count >= 4 { self.apply(props) } }
        }
    }

    // MARK: - Liveness: detect a lamp that went offline or changed its DHCP IP, then reconnect

    private func startPollTimer() {
        pollTimer?.invalidate()
        pollMisses = 0
        pollEpoch &+= 1            // invalidate any in-flight read from a previous connection
        let t = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPoll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// Periodic liveness probe. Only counts failures toward "lost" when the lamp is supposed to
    /// be ON — a deliberately powered-off lamp that also drops off WiFi must not trigger reconnect.
    private func tickPoll() {
        guard let device, connected else { return }
        let expectOn = power
        let epoch = pollEpoch
        Task.detached {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power", "rgb", "main_power"])) ?? []
            await MainActor.run {
                guard self.connected, epoch == self.pollEpoch else { return }   // ignore stale/superseded reads
                if props.count >= 4 {
                    self.pollMisses = 0
                    // Don't fight live sync: bg_rgb/bright are being driven ~20 Hz, so re-applying
                    // them here would snap the colour/brightness controls every tick.
                    if !(self.screenSyncOn || self.musicSyncOn) { self.apply(props) }
                } else if expectOn {
                    self.pollMisses += 1
                    if self.pollMisses >= 3 { self.handleLost() }   // ~3 misses ≈ 36 s of silence
                }
            }
        }
    }

    /// Lamp stopped answering (offline or DHCP IP changed) — re-discover by stable id and reconnect.
    private func handleLost() {
        pollTimer?.invalidate(); pollTimer = nil
        pollMisses = 0
        stopScreenSync(); stopMusicSync()
        connected = false
        connectError = "Связь с лампой потеряна — переподключаюсь…"
        let savedID = UserDefaults.standard.string(forKey: savedIDKey) ?? ""
        let savedIP = UserDefaults.standard.string(forKey: savedIPKey) ?? ""
        isSearching = true
        Task.detached {
            let found = YeelightDiscovery.auto()
            await MainActor.run {
                self.isSearching = false
                self.devices = found
                let match = found.first(where: { !savedID.isEmpty && $0.id == savedID })
                         ?? found.first(where: { !savedIP.isEmpty && $0.ip == savedIP })
                if let match {
                    self.connect(to: match)
                } else {
                    self.connectError = "Лампа не в сети. Нажми «Автопоиск», когда она вернётся."
                }
            }
        }
    }

    private func apply(_ props: [String]) {
        // props: [power, bright, ct, bg_rgb, bg_power, rgb, main_power]
        brightness = Double(props[1]) ?? brightness
        colorTempK = Double(props[2]) ?? colorTempK
        if selectedIsBar {
            // The bar's front light is reported by main_power; its `power` prop sticks at "on"
            // even when the front is dark, so never trust `power` for the front state here.
            power = (props.count > 6 ? props[6] : props[0]) == "on"
            if let rgb = Int(props[3]), rgb > 0 { ambientColor = Color(rgb: rgb) }
            if props.count > 4 { ambientOn = (props[4] == "on") }
        } else {
            power = (props[0] == "on")                  // strips report front state honestly
            if props.count > 5, let rgb = Int(props[5]), rgb > 0 { ambientColor = Color(rgb: rgb) }
            ambientOn = power
        }
    }

    // MARK: - Control (push current published value to the lamp)

    /// True for the Screen Light Bar Pro (lamp15) — it ignores `set_power off` and only
    /// responds to `dev_toggle`. Plain strips/bulbs reject `dev_toggle` ("method not
    /// supported") and need ordinary `set_power`.
    private var selectedIsBar: Bool {
        guard let d = selected else { return false }
        return d.support.contains("bg_set_rgb") || d.model == "lamp15"
    }

    /// Whole-device on indicator: true if either channel is lit.
    var masterOn: Bool { power || ambientOn }

    /// Master power: turn the WHOLE device on/off (front white + ambient together). Uses explicit
    /// per-channel set_power/bg_set_power — deterministic, so the UI and device never disagree.
    func togglePower() {
        let target = !masterOn
        if !target { stopScreenSync(); stopMusicSync() }
        power = target
        push { try $0.power(target) }                     // front / main channel
        if selectedIsBar {
            ambientOn = target
            let v = target ? "on" : "off"
            push { try $0.control("bg_set_power", [v, "smooth", 300]) }   // ambient channel
        } else {
            ambientOn = target                            // single-channel device
        }
        scheduleResync()
    }

    /// Front white channel ONLY (the bar's main light). Leaves the ambient channel untouched —
    /// switch this off to run "только подсветка". On a single-channel strip this is the whole light.
    func setFrontPower(_ on: Bool) {
        power = on
        if !selectedIsBar { ambientOn = on }              // single channel: front == the only light
        push { try $0.power(on) }
        scheduleResync()
    }

    /// Debounced ambient-colour push — coalesces ColorPicker drags so we never
    /// exceed the lamp's ~60 cmd/min TCP quota.
    func setAmbient(_ c: Color) {
        if screenSyncOn { stopScreenSync() }   // a static colour replaces live screen-sync
        ambientColor = c
        ambientOn = true
        ambientWork?.cancel()
        let powerMethod = colorPowerMethod
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.push { try $0.control(powerMethod, ["on", "smooth", 0]) } // ensure the colour channel is on
            self.pushAmbient()
        }
        ambientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func pushBrightness() { let v = Int(brightness); push { try $0.setBrightness(v) } }
    func pushColorTemp() { let k = Int(colorTempK); push { try $0.setColorTemp(k) } }
    func pushAmbient() {
        let rgb = ambientColor.rgbInt
        if selectedIsBar { push { try $0.setAmbientRGB(rgb) } }       // bar: separate bg channel
        else { push { try $0.control("set_rgb", [rgb & 0xFFFFFF, "smooth", 300]) } } // strip/bulb: main channel
    }

    /// The colourful channel's power method: the bar has a separate "bg" channel; a plain
    /// strip/bulb has only its main channel.
    private var colorPowerMethod: String { selectedIsBar ? "bg_set_power" : "set_power" }

    /// Independent on/off for the colour channel.
    func setAmbientPower(_ on: Bool) {
        if !on { stopScreenSync(); stopMusicSync() }   // colour off → stop any running sync
        ambientOn = on
        if !selectedIsBar { power = on }               // single-channel device: colour power == device power
        let m = colorPowerMethod
        let v = on ? "on" : "off"
        push { try $0.control(m, [v, "smooth", 300]) }
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
        let targets = syncTargets()
        guard !targets.isEmpty else {
            screenSyncStatus = "Назначь зону экрана хотя бы одной лампе."
            return
        }
        stopMusicSync()              // screen-sync and music-sync are mutually exclusive
        ambientOn = true             // sync turns the backlight on — reflect it in the toggle
        screenSyncOn = true            // optimistic; reverted by onState on failure
        screenSyncStatus = "Запуск…"
        let m = colorPowerMethod
        push { try $0.control(m, ["on", "smooth", 200]) }   // ensure the colour channel is on
        sync.start(targets: targets)
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
        let m = colorPowerMethod
        push { try $0.control(m, ["on", "smooth", 200]) }   // ensure the colour channel is on
        music.start(targets: syncTargets())   // same opt-in set as screen sync (region ignored for music)
    }

    func stopMusicSync() {
        let wasOn = musicSyncOn
        music.stop()
        musicSyncOn = false
        musicSyncStatus = nil
        if wasOn { ambientColor = syncColor; ambientOn = true }
    }

    // MARK: - Multi-device sync targets (each lamp samples its own screen region)

    /// Devices that participate in sync (screen AND music): the connected primary always does
    /// (using its chosen zone, default top), plus any OTHER device the user has EXPLICITLY assigned
    /// a zone to. Devices the user never opted in (no zone) are left untouched — so selecting music
    /// while on the strip won't silently grab every other lamp in the home.
    private func syncTargets() -> [SyncTarget] {
        var out: [SyncTarget] = []
        if let d = selected {
            out.append(SyncTarget(ip: d.ip, port: d.port, method: streamMethod(for: d), region: syncRegions[d.ip] ?? .top))
        }
        for d in devices where d.ip != selected?.ip {
            guard let region = syncRegions[d.ip] else { continue }
            out.append(SyncTarget(ip: d.ip, port: d.port, method: streamMethod(for: d), region: region))
        }
        return out
    }

    func setRegion(_ ip: String, _ region: SyncRegion?) {
        if let region { syncRegions[ip] = region } else { syncRegions.removeValue(forKey: ip) }
    }

    /// What the zone menu should display: the connected primary always participates (default top),
    /// so it never shows «Выкл»; other devices show their explicit zone or nil («Выкл»).
    func displayRegion(_ ip: String) -> SyncRegion? {
        if ip == selected?.ip { return syncRegions[ip] ?? .top }
        return syncRegions[ip]
    }

    /// bg-capable lamps stream the ambient channel; plain RGB strips stream the main channel.
    /// Scan/manual devices may carry an empty SSDP support list — fall back to the known bar model.
    private func streamMethod(for d: DiscoveredDevice) -> String {
        (d.support.contains("bg_set_rgb") || d.model == "lamp15") ? "bg_set_rgb" : "set_rgb"
    }

    private func restartSync() {
        if screenSyncOn {
            let t = syncTargets()
            if t.isEmpty {
                stopScreenSync()
                screenSyncStatus = "Назначь зону экрана хотя бы одной лампе."
            } else {
                sync.stop(); sync.start(targets: t)
            }
        }
        if musicSyncOn { music.stop(); music.start(targets: syncTargets()) }
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
