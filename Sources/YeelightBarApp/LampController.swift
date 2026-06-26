import SwiftUI
import AppKit
import CoreGraphics
import YeelightKit

enum SyncMode: Hashable { case off, screen, music }

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
    let label: String
}

/// Bridges SwiftUI to YeelightKit: device finding + live control.
@MainActor
final class LampController: ObservableObject {
    // Device finding
    @Published var devices: [DiscoveredDevice] = []
    @Published var selected: DiscoveredDevice?              // the "primary": drives state read-back + UI
    @Published var groupIPs: Set<String> = []              // every device under control (multi-select)
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
    @Published var displays: [DisplayInfo] = []
    @Published var captureDisplayID: CGDirectDisplayID = 0 {
        didSet {
            sync.preferredDisplayID = captureDisplayID
            if let d = displays.first(where: { $0.id == captureDisplayID }) { captureInfo = "\(d.width)×\(d.height)" }
            if screenSyncOn { sync.stop(); sync.start(targets: syncTargets()) }   // recapture from the chosen screen
        }
    }
    @Published var bandFraction: Double = 0.25 { didSet { sync.bandFraction = bandFraction } }
    @Published var brightnessFollow = false
    @Published var syncSmoothing: Double = 0.35 { didSet { sync.smoothing = syncSmoothing } }
    @Published var syncSaturation: Double = 1.25 { didSet { sync.saturation = syncSaturation } }
    @Published var musicSensitivity: Double = 4.0 { didSet { music.sensitivity = musicSensitivity } }
    @Published var musicStyle: MusicStyle = .beat { didSet { music.style = musicStyle } }
    @Published var syncRegions: [String: SyncRegion] = [:] { didSet { if !suppressRegionRestart, screenSyncOn || musicSyncOn { restartSync() } } }
    private var suppressRegionRestart = false   // set while a group edit handles its own single restart
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
    /// All TCP control/read traffic to the connected lamp is serialized here — the bar drops a
    /// command if two connections hit it at once (e.g. set_power + bg_set_power racing).
    private let io = DispatchQueue(label: "yeelightbar.control")
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
        refreshDisplays()
        sync.preferredDisplayID = captureDisplayID   // didSet doesn't fire during init
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
                self.reconcileGroup(against: found)   // drop any grouped lamp that vanished from the scan
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

    /// Explicit "connect": focus on ONE device — it becomes the primary and the only group member.
    func connect(to d: DiscoveredDevice?) {
        guard let d else { return }
        stopScreenSync()
        stopMusicSync()
        groupIPs = [d.ip]        // a single explicit connect resets the control group
        setPrimary(d)
    }

    /// Point the primary (state read-back source) at a device without touching group membership.
    private func setPrimary(_ d: DiscoveredDevice) {
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

    /// Add/remove a device from the control group (multi-select "mix"). The first member becomes
    /// the primary; removing the primary re-points it to another member (or disconnects if empty).
    func toggleGroup(_ d: DiscoveredDevice) {
        if groupIPs.contains(d.ip) {
            groupIPs.remove(d.ip)
            if selected?.ip == d.ip {
                if let nip = groupIPs.first, let next = devices.first(where: { $0.ip == nip }) {
                    setPrimary(next)
                } else {                       // group is now empty
                    pollTimer?.invalidate(); pollTimer = nil
                    stopScreenSync(); stopMusicSync()
                    selected = nil; device = nil; connected = false
                }
            }
            suppressRegionRestart = true        // the single restart below covers this removal
            syncRegions.removeValue(forKey: d.ip)
            suppressRegionRestart = false
        } else {
            groupIPs.insert(d.ip)
            if selected == nil { setPrimary(d) }
        }
        if screenSyncOn || musicSyncOn { restartSync() }   // one restart re-targets a running effect
    }

    /// Make an already-grouped device the primary (whose state the sliders/toggles reflect).
    func makePrimary(_ d: DiscoveredDevice) {
        guard groupIPs.contains(d.ip), selected?.ip != d.ip else { return }
        setPrimary(d)
    }

    /// After the device list is replaced by a (re)scan, drop group members / a primary that
    /// vanished — otherwise they linger as phantom IPs (un-removable in the UI, silent no-op
    /// in fanOut, and a stuck "connected" header if the primary itself disappeared).
    private func reconcileGroup(against found: [DiscoveredDevice]) {
        let live = Set(found.map { $0.ip })
        let before = groupIPs
        groupIPs.formIntersection(live)
        suppressRegionRestart = true
        syncRegions = syncRegions.filter { live.contains($0.key) }
        suppressRegionRestart = false
        if let sel = selected, !live.contains(sel.ip) {       // primary itself vanished
            if let nip = groupIPs.first, let next = found.first(where: { $0.ip == nip }) {
                setPrimary(next)
            } else {
                pollTimer?.invalidate(); pollTimer = nil
                stopScreenSync(); stopMusicSync()
                selected = nil; device = nil; connected = false
            }
        }
        if groupIPs != before, screenSyncOn || musicSyncOn { restartSync() }
    }

    func backToDevices() { pollTimer?.invalidate(); pollTimer = nil; connected = false }

    func refresh() {
        guard let device else { connecting = false; return }
        let ip = selected?.ip ?? ""
        io.async {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power", "rgb", "main_power"])) ?? []
            Task { @MainActor in
                guard self.selected?.ip == ip else { return }   // primary re-pointed / group emptied mid-read
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
        io.async {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power", "rgb", "main_power"])) ?? []
            Task { @MainActor in if props.count >= 4 { self.apply(props) } }
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
        io.async {
            let props = (try? device.properties(["power", "bright", "ct", "bg_rgb", "bg_power", "rgb", "main_power"])) ?? []
            Task { @MainActor in
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
                let oldIP = self.selected?.ip
                self.devices = found
                let live = Set(found.map { $0.ip })
                let match = found.first(where: { !savedID.isEmpty && $0.id == savedID })
                         ?? found.first(where: { !savedIP.isEmpty && $0.ip == savedIP })
                if let match {
                    // Re-point the primary WITHOUT wiping the group; on a DHCP change carry its zone
                    // to the new IP, and drop any other members that didn't come back in the scan.
                    if let oldIP, oldIP != match.ip {
                        self.suppressRegionRestart = true
                        if let z = self.syncRegions.removeValue(forKey: oldIP) { self.syncRegions[match.ip] = z }
                        self.suppressRegionRestart = false
                    }
                    self.groupIPs = self.groupIPs.intersection(live).union([match.ip])
                    self.setPrimary(match)
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

    // MARK: - Control (fans out to every device in the control group)

    /// True when a device has a separate bg/ambient channel (the Screen Light Bar Pro, lamp15).
    private func isBar(_ d: DiscoveredDevice?) -> Bool {
        guard let d else { return false }
        return d.support.contains("bg_set_rgb") || d.model == "lamp15"
    }
    private var selectedIsBar: Bool { isBar(selected) }

    /// Whole-device on indicator (reflects the primary): true if either channel is lit.
    var masterOn: Bool { power || ambientOn }

    /// The colour channel's power method for the primary device.
    private var colorPowerMethod: String { selectedIsBar ? "bg_set_power" : "set_power" }

    /// Every device currently in the control group, tagged bar vs plain strip/bulb.
    private func controlTargets() -> [(dev: YeelightDevice, isBar: Bool)] {
        devices.filter { groupIPs.contains($0.ip) }
               .map { (YeelightDevice(ip: $0.ip, tcpPort: $0.port), isBar($0)) }
    }

    /// Run a control op on every group member, serialized on `io` so no two TCP connections race.
    private func fanOut(_ op: @escaping (YeelightDevice, Bool) -> Void) {
        let targets = controlTargets()
        guard !targets.isEmpty else { return }
        io.async { for t in targets { op(t.dev, t.isBar) } }
    }
    /// Fire-and-forget control with a short reply wait — the lamp acts whether or not we read it.
    nonisolated private func send(_ dev: YeelightDevice, _ method: String, _ params: [Any]) {
        _ = try? dev.control(method, params, readTimeout: 0.25)
    }

    /// Master power for every group member: front white + ambient together.
    func togglePower() {
        let target = !masterOn
        if !target { stopScreenSync(); stopMusicSync() }
        power = target; ambientOn = target
        let v = target ? "on" : "off"
        fanOut { dev, isBar in
            self.send(dev, "set_power", [v, "smooth", 300])
            if isBar { self.send(dev, "bg_set_power", [v, "smooth", 300]) }
        }
        scheduleResync()
    }

    /// Front white channel only (the bar's main light); on a strip this is the whole light.
    func setFrontPower(_ on: Bool) {
        power = on
        if !selectedIsBar { ambientOn = on }
        let v = on ? "on" : "off"
        fanOut { dev, _ in self.send(dev, "set_power", [v, "smooth", 300]) }
        scheduleResync()
    }

    /// Debounced colour push — coalesces drags so we stay under the lamp's ~60 cmd/min TCP quota.
    func setAmbient(_ c: Color) {
        if screenSyncOn { stopScreenSync() }   // a static colour replaces live screen-sync
        ambientColor = c
        ambientOn = true
        ambientWork?.cancel()
        let rgb = c.rgbInt
        let work = DispatchWorkItem { [weak self] in
            self?.fanOut { dev, isBar in
                if isBar {
                    self?.send(dev, "bg_set_power", ["on", "smooth", 0])
                    self?.send(dev, "bg_set_rgb", [rgb & 0xFFFFFF, "smooth", 300])
                } else {
                    self?.send(dev, "set_power", ["on", "smooth", 0])
                    self?.send(dev, "set_rgb", [rgb & 0xFFFFFF, "smooth", 300])
                }
            }
        }
        ambientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func pushBrightness() { let v = max(1, min(100, Int(brightness))); fanOut { dev, _ in self.send(dev, "set_bright", [v, "smooth", 300]) } }
    func pushColorTemp() { let k = max(1700, min(6500, Int(colorTempK))); fanOut { dev, _ in self.send(dev, "set_ct_abx", [k, "smooth", 300]) } }
    func pushAmbient() {
        let rgb = ambientColor.rgbInt
        fanOut { dev, isBar in self.send(dev, isBar ? "bg_set_rgb" : "set_rgb", [rgb & 0xFFFFFF, "smooth", 300]) }
    }

    /// Independent on/off for the colour channel (bar = bg channel, strip = its only channel).
    func setAmbientPower(_ on: Bool) {
        if !on { stopScreenSync(); stopMusicSync() }   // colour off → stop any running sync
        ambientOn = on
        if !selectedIsBar { power = on }               // single-channel device: colour power == device power
        let v = on ? "on" : "off"
        fanOut { dev, isBar in self.send(dev, isBar ? "bg_set_power" : "set_power", [v, "smooth", 300]) }
    }

    func applyScene(ct: Int, bright: Int) {
        power = true
        colorTempK = Double(ct)
        brightness = Double(bright)
        // one atomic command sets CT + brightness together → identical every press
        fanOut { dev, _ in self.send(dev, "set_scene", ["ct", ct, bright]) }
        scheduleResync()
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
        fanOut { dev, isBar in self.send(dev, isBar ? "bg_set_power" : "set_power", ["on", "smooth", 200]) } // colour channel on
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
        fanOut { dev, isBar in self.send(dev, isBar ? "bg_set_power" : "set_power", ["on", "smooth", 200]) } // colour channel on
        music.start(targets: syncTargets())   // drives the whole control group (region ignored for music)
    }

    func stopMusicSync() {
        let wasOn = musicSyncOn
        music.stop()
        musicSyncOn = false
        musicSyncStatus = nil
        if wasOn { ambientColor = syncColor; ambientOn = true }
    }

    // MARK: - Multi-device sync targets (each lamp samples its own screen region)

    /// Devices that participate in sync (screen AND music): exactly the control group. Each samples
    /// its chosen screen zone (default top); music ignores the zone. Nothing outside the group is
    /// ever touched — so an effect only drives the lamps you explicitly added.
    private func syncTargets() -> [SyncTarget] {
        devices.filter { groupIPs.contains($0.ip) }.map { d in
            SyncTarget(ip: d.ip, port: d.port, method: streamMethod(for: d), region: syncRegions[d.ip] ?? .top)
        }
    }

    func setRegion(_ ip: String, _ region: SyncRegion?) {
        if let region { syncRegions[ip] = region } else { syncRegions.removeValue(forKey: ip) }
    }

    /// Zone shown in the menu: a group member defaults to top (never «Выкл»); others show nil.
    func displayRegion(_ ip: String) -> SyncRegion? {
        guard groupIPs.contains(ip) else { return nil }
        return syncRegions[ip] ?? .top
    }

    /// bg-capable lamps stream the ambient channel; plain RGB strips stream the main channel.
    /// Scan/manual devices may carry an empty SSDP support list — fall back to the known bar model.
    private func streamMethod(for d: DiscoveredDevice) -> String {
        (d.support.contains("bg_set_rgb") || d.model == "lamp15") ? "bg_set_rgb" : "set_rgb"
    }

    /// Turn the colour channel on for every current group member (a lamp just added mid-sync
    /// has its UDP stream opened but is never powered on otherwise → would stay dark).
    private func ensureColourChannelsOn() {
        fanOut { dev, isBar in self.send(dev, isBar ? "bg_set_power" : "set_power", ["on", "smooth", 200]) }
    }

    private func restartSync() {
        if screenSyncOn {
            let t = syncTargets()
            if t.isEmpty {
                stopScreenSync()
                screenSyncStatus = "Назначь зону экрана хотя бы одной лампе."
            } else {
                ensureColourChannelsOn()
                sync.stop(); sync.start(targets: t)
            }
        }
        if musicSyncOn { ensureColourChannelsOn(); music.stop(); music.start(targets: syncTargets()) }
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

    /// Enumerate attached displays (synchronous CoreGraphics — no Screen-Recording permission needed)
    /// so the user can choose which screen to sync from. Falls back to main if the choice disappears.
    func refreshDisplays() {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        guard n > 0 else { displays = []; return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        ids = Array(ids.prefix(Int(n)))
        let main = CGMainDisplayID()
        displays = ids.map { id in
            DisplayInfo(id: id, width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id),
                        label: "\(CGDisplayPixelsWide(id))×\(CGDisplayPixelsHigh(id))" + (id == main ? " · основной" : ""))
        }
        if captureDisplayID == 0 || !ids.contains(captureDisplayID) { captureDisplayID = main }
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
        fanOut { dev, _ in self.send(dev, "set_bright", [target, "smooth", 300]) }
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
