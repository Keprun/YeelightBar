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

    private let vid = 0x3434
    private let cablePID = 0x0913
    private let donglePID = 0xD030
    private let usagePage = 0xFF60
    private let usage = 0x61
    private let reportLen = 32

    /// VIA: id_custom_set_value, channel = qmk_rgb_matrix(3), value ids brightness=1 / effect=2 / color=4.
    private enum V {
        static let setValue: UInt8 = 0x07
        static let rgbChannel: UInt8 = 0x03
        static let brightness: UInt8 = 1
        static let effect: UInt8 = 2
        static let color: UInt8 = 4
        static let solidColor: UInt8 = 1   // RGB_MATRIX_SOLID_COLOR
    }

    /// Fired (on the main queue) whenever the link state changes — drives the UI.
    var onLink: ((Link) -> Void)?
    private(set) var link: Link = .none

    private let io = DispatchQueue(label: "yeelightbar.keychron")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var effectArmed = false   // re-assert SOLID_COLOR once per session

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
            me.io.async { me.device = nil; me.effectArmed = false; me.refreshLink() }
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
        func pid(_ d: IOHIDDevice) -> Int { (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0 }
        if let cable = set.first(where: { pid($0) == cablePID }) {
            guard IOHIDDeviceOpen(cable, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                setLink(.none); return false   // cable present but couldn't open (busy) — not usable
            }
            device = cable; effectArmed = false; setLink(.cable); return true
        }
        setLink(set.contains(where: { pid($0) == donglePID }) ? .dongle : .none)   // dongle present but unusable for RGB
        return false
    }

    private func refreshLink() { _ = ensureOpen() }

    private func setLink(_ l: Link) {
        guard l != link else { return }
        link = l
        DispatchQueue.main.async { self.onLink?(l) }
    }

    // MARK: - Output

    private func send(_ d: IOHIDDevice, _ payload: [UInt8]) {
        var buf = payload
        if buf.count < reportLen { buf += [UInt8](repeating: 0, count: reportLen - buf.count) }
        let rc = buf.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, $0.baseAddress!, reportLen)
        }
        if rc != kIOReturnSuccess { device = nil; effectArmed = false }   // drop & reopen next frame; removal callback handles link
    }

    /// Re-arm SOLID_COLOR on the next colour (call when an ambilight session starts).
    func beginSession() { io.async { self.effectArmed = false } }

    /// Drive the whole matrix to this 0xRRGGBB colour. No-op unless connected by cable.
    func setColor(_ rgb: Int) {
        io.async {
            guard self.ensureOpen(), let d = self.device, self.link == .cable else { return }
            if !self.effectArmed {
                self.send(d, [V.setValue, V.rgbChannel, V.effect, V.solidColor])
                self.effectArmed = true
            }
            let (h, s, v) = Self.rgbToHSV(rgb)
            self.send(d, [V.setValue, V.rgbChannel, V.color, h, s])
            self.send(d, [V.setValue, V.rgbChannel, V.brightness, v])
        }
    }

    /// Probe the link without sending (for the UI to show cable/dongle/none).
    func refresh() { io.async { self.refreshLink() } }

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
