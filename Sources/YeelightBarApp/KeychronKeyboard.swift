import Foundation
import IOKit
import IOKit.hid

/// Live RGB-matrix ambilight for a Keychron (QMK/VIA) keyboard over Raw HID.
///
/// Send-only: drives VIA's "QMK RGB matrix" custom channel (channel 3) to set the whole matrix to a
/// solid colour each frame — `set effect = SOLID_COLOR`, then `set color = (hue,sat)` + `set brightness`.
/// No EEPROM save (no wear). VIA commands only pass over the USB **cable** (PID 0x0913); the 2.4 GHz
/// dongle's raw-HID interface (0xD030) is a dead end, so colour is a no-op there.
///
/// All device I/O is confined to `io`; IOKit arrival/removal callbacks only enqueue onto it.
final class KeychronKeyboard {
    enum Link: Equatable { case none, dongle, cable }

    private let vid = 0x3434       // Keychron (matches ALL its QMK/VIA keyboards, no per-model PID)
    private let usagePage = 0xFF60
    private let usage = 0x61
    private let reportLen = 32

    /// VIA id_custom_set_value. We drive BOTH custom RGB channels so any Keychron works: per-key
    /// rgb_matrix (3) and underglow rgblight (2). value ids: brightness=1, effect=2, color=4.
    private enum V {
        static let setValue: UInt8 = 0x07
        static let rgbMatrix: UInt8 = 0x03
        static let rgbLight: UInt8 = 0x02
        static let brightness: UInt8 = 1
        static let effect: UInt8 = 2
        static let color: UInt8 = 4
        static let solid: UInt8 = 1   // SOLID_COLOR (matrix) / STATIC_LIGHT (rgblight) are both mode 1
    }

    /// Fired (on the main queue) when link state or detected model changes — drives the UI.
    var onLink: ((Link, String) -> Void)?
    private(set) var link: Link = .none
    private(set) var model = "Keychron"
    private var lastModel = ""

    /// Fired (on main) with battery % when the keyboard reports it (custom 0xA4 firmware command, cable).
    var onBattery: ((Int) -> Void)?

    private let io = DispatchQueue(label: "yeelightbar.keychron")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var lastArm = Date.distantPast    // periodically re-assert the solid effect
    private var lastSend = Date.distantPast
    private let inputBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
    private var batteryTimer: DispatchSourceTimer?

    init() { io.async { self.setupManager() } }

    // MARK: - Device discovery

    private func setupManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: vid, kIOHIDDeviceUsagePageKey: usagePage, kIOHIDDeviceUsageKey: usage,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<KeychronKeyboard>.fromOpaque(context).takeUnretainedValue()
            me.io.async { me.device = nil; me.lastArm = .distantPast; me.refreshLink() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, cb, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, cb, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        refreshLink()
    }

    /// Pick the cable interface (0x0913) if present; only then can we drive RGB. Cache the open device.
    @discardableResult private func ensureOpen() -> Bool {
        if device != nil { return true }
        guard let mgr = manager, let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            setLink(.none); return false
        }
        func product(_ d: IOHIDDevice) -> String {
            ((IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "").trimmingCharacters(in: .whitespaces)
        }
        // The wired keyboard reports its MODEL ("Keychron K8 Pro", "V1 Max", …); the 2.4 GHz
        // receiver reports "Keychron Link" and is a dead end for VIA. Pick the real keyboard.
        func isReceiver(_ d: IOHIDDevice) -> Bool {
            let p = product(d).lowercased()
            return p.contains("link") || p.contains("receiver") || p.contains("dongle")
        }
        if let kbd = set.first(where: { !isReceiver($0) }) {
            guard IOHIDDeviceOpen(kbd, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                setLink(.none); return false   // present but couldn't open (busy) — not usable
            }
            device = kbd; lastArm = .distantPast
            let name = product(kbd); model = name.isEmpty ? "Keychron" : name
            // listen for VIA responses on this device (we only act on the 0xA4 battery reply)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(kbd, inputBuf, 32, { context, _, _, _, _, report, length in
                guard let context, length >= 2, report[0] == 0xA4 else { return }   // [0xA4, pct, mv_lo, mv_hi]
                let pct = Int(report[1])
                if pct >= 1, pct <= 100 {
                    let me = Unmanaged<KeychronKeyboard>.fromOpaque(context).takeUnretainedValue()
                    DispatchQueue.main.async { me.onBattery?(pct) }
                }
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(kbd, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            startBatteryPoll()
            setLink(.cable); return true
        }
        setLink(.dongle)   // only a 2.4 GHz receiver present → RGB unavailable until cabled
        return false
    }

    private func refreshLink() { _ = ensureOpen() }

    private func setLink(_ l: Link) {
        let m = model
        guard l != link || m != lastModel else { return }
        link = l; lastModel = m
        DispatchQueue.main.async { self.onLink?(l, m) }
    }

    // MARK: - Output

    private func send(_ d: IOHIDDevice, _ payload: [UInt8]) {
        var buf = payload
        if buf.count < reportLen { buf += [UInt8](repeating: 0, count: reportLen - buf.count) }
        let rc = buf.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, $0.baseAddress!, reportLen)
        }
        if rc != kIOReturnSuccess { device = nil; lastArm = .distantPast }   // drop & reopen next frame; removal callback handles link
    }

    /// Re-arm SOLID_COLOR on the next colour (call when an ambilight session starts).
    func beginSession() { io.async { self.lastArm = .distantPast } }

    /// Drive the whole matrix to this 0xRRGGBB colour. No-op unless connected by cable.
    func setColor(_ rgb: Int) {
        io.async {
            let now = Date()
            guard now.timeIntervalSince(self.lastSend) >= 0.03 else { return }   // cap ~30 Hz (music can fire faster)
            guard self.ensureOpen(), let d = self.device, self.link == .cable else { return }
            self.lastSend = now
            let (h, s, v) = Self.rgbToHSV(rgb)
            if now.timeIntervalSince(self.lastArm) > 2 {   // (re)assert solid every ~2s so a stray RGB key can't strand an animation
                self.send(d, [V.setValue, V.rgbMatrix, V.effect, V.solid])   // per-key matrix → solid
                self.send(d, [V.setValue, V.rgbLight, V.effect, V.solid])    // underglow → static
                self.lastArm = now
            }
            // drive both custom channels; the one the firmware lacks is a harmless no-op (id_unhandled)
            self.send(d, [V.setValue, V.rgbMatrix, V.color, h, s]); self.send(d, [V.setValue, V.rgbMatrix, V.brightness, v])
            self.send(d, [V.setValue, V.rgbLight, V.color, h, s]); self.send(d, [V.setValue, V.rgbLight, V.brightness, v])
        }
    }

    /// Probe the link without sending (for the UI to show cable/dongle/none).
    func refresh() { io.async { self.refreshLink() } }

    private func startBatteryPoll() {
        batteryTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: io)
        t.schedule(deadline: .now() + 1, repeating: 60)
        t.setEventHandler { [weak self] in self?.readBattery() }
        t.resume()
        batteryTimer = t
    }
    /// Ask for battery % (custom 0xA4 firmware command); the firmware replies via the input callback.
    private func readBattery() {
        guard let d = device, link == .cable else { return }
        send(d, [0xA4])
    }

    static func rgbToHSV(_ rgb: Int) -> (h: UInt8, s: UInt8, v: UInt8) {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r      { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else            { h = (r - g) / d + 4 }
            h *= 60; if h < 0 { h += 360 }
        }
        let s = mx == 0 ? 0 : d / mx
        return (UInt8(min(255, h / 360 * 255)), UInt8(s * 255), UInt8(mx * 255))
    }
}
