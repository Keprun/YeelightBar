import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import YeelightKit

enum SyncRegion: String, Hashable, CaseIterable { case top, bottom, left, right, full }

struct SyncTarget { let ip: String; let port: UInt16; let method: String; let region: SyncRegion }

/// Fans colour out to one or more lamps, each with its own UDP session and screen region.
/// All device socket I/O is serialized on a private queue so it never blocks the capture
/// thread and never races the per-device UDP fd/token.
final class SyncOutput {
    private let targets: [(device: YeelightDevice, region: SyncRegion)]
    private let io = DispatchQueue(label: "yeelightbar.syncoutput")
    init(_ ts: [SyncTarget]) {
        targets = ts.map { t in
            let d = YeelightDevice(ip: t.ip, tcpPort: t.port)
            d.streamMethod = t.method
            return (d, t.region)
        }
    }
    /// Distinct regions across all targets (immutable — safe to read from any thread).
    var regions: Set<SyncRegion> { Set(targets.map { $0.region }) }
    var isEmpty: Bool { targets.isEmpty }

    func openStream() { io.async { self.targets.forEach { _ = try? $0.device.openStream(timeout: 1.5) } } }
    /// Recovery: re-acquire a token for any target whose session has dropped.
    func ensureStreams() { io.async { self.targets.forEach { if $0.device.streamToken == nil { _ = try? $0.device.openStream(timeout: 0.8) } } } }
    func stream(rgb: Int) { io.async { self.targets.forEach { $0.device.stream(rgb: rgb) } } }            // music: same to all
    func streamRegion(_ region: SyncRegion, rgb: Int) {                                                     // screen: per region
        io.async { for t in self.targets where t.region == region { t.device.stream(rgb: rgb) } }
    }
    func keepAlive() { io.async { self.targets.forEach { $0.device.keepAlive() } } }
    func closeStream() { io.async { self.targets.forEach { $0.device.closeStream() } } }
}

/// Ambilight engine: captures the display via ScreenCaptureKit and streams the
/// representative colour of each target's screen region to that target's lamp.
///
/// Lifecycle invariant: `stream`, `out`, `frameCount`, `smoothedByRegion`, `keepAliveTimer`
/// and `generation` are touched ONLY on `queue`. start()/stop() enqueue onto `queue`, the
/// SCStream sample handler runs on `queue`, and every async setup callback hops back onto
/// `queue` and re-checks `generation` so a late callback can't resurrect a torn-down capture.
final class ScreenSyncEngine: NSObject, SCStreamOutput {
    var onState: ((Bool, String?) -> Void)?
    var onColor: ((Int) -> Void)?
    var onRegionColors: (([SyncRegion: Int]) -> Void)?
    var onSource: ((Int, Int) -> Void)?
    var onLuma: ((Double) -> Void)?
    var bandFraction: Double = 0.25
    var smoothing: Double = 0.35
    var saturation: Double = 1.25
    var preferredDisplayID: CGDirectDisplayID = 0   // 0 → main display; else capture this specific screen

    private var stream: SCStream?
    private var out: SyncOutput?
    private let queue = DispatchQueue(label: "yeelightbar.screensync")
    private var smoothedByRegion: [SyncRegion: (r: Double, g: Double, b: Double)] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    private var kaTick = 0
    private var frameCount = 0
    private var generation = 0   // bumped on every start()/stop(); guards async setup callbacks

    func start(targets: [SyncTarget]) {
        queue.async {
            self.generation += 1
            let gen = self.generation
            self.frameCount = 0
            self.smoothedByRegion = [:]
            let o = SyncOutput(targets)
            self.out = o
            o.openStream()
            self.startKeepAlive()
            self.beginCapture(gen: gen)
        }
    }

    func stop() {
        queue.async { self.generation += 1; self.teardown() }
    }

    // MARK: - Capture setup (all callbacks hop back onto `queue` and re-check generation)

    private func beginCapture(gen: Int) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                guard gen == self.generation else { return }   // superseded by stop()/restart
                if error != nil {
                    self.teardown()
                    self.report(false, "Нет доступа к захвату экрана. Разреши «Запись экрана» и перезапусти приложение.")
                    return
                }
                let want = self.preferredDisplayID
                guard let display = content?.displays.first(where: { $0.displayID == want && want != 0 })
                                 ?? content?.displays.first(where: { $0.displayID == CGMainDisplayID() })
                                 ?? content?.displays.first else {
                    self.teardown(); self.report(false, "Не найден дисплей для захвата."); return
                }
                self.reportSource(display.width, display.height)

                // Resolution-independent capture: keep the display's EXACT aspect (no letterbox)
                // and scale the longer edge to a fixed target, so sampling density is the same on a
                // 16:9 laptop, a 4K panel, a portrait monitor, or a 32:9 5120×1440 ultrawide.
                let dw = max(1, display.width), dh = max(1, display.height)
                let scale = 192.0 / Double(max(dw, dh))
                func even(_ x: Double) -> Int { let n = max(16, Int(x.rounded())); return n - (n % 2) }
                let capW = even(Double(dw) * scale)
                let capH = even(Double(dh) * scale)
                let config = SCStreamConfiguration()
                config.width = capW
                config.height = capH
                config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3
                config.showsCursor = false

                let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                                      configuration: config, delegate: nil)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.teardown(); self.report(false, "addStreamOutput: \(error.localizedDescription)"); return
                }
                stream.startCapture { err in
                    self.queue.async {
                        guard gen == self.generation else { stream.stopCapture(completionHandler: { _ in }); return }
                        if let err {
                            self.teardown(); self.report(false, "Не удалось начать захват: \(err.localizedDescription).")
                        } else {
                            self.stream = stream
                            self.report(true, nil)
                        }
                    }
                }
            }
        }
    }

    /// Independent keep-alive + session-recovery timer (NOT gated on frame arrival, so a
    /// static screen — which makes SCK stop delivering frames — can't let the session expire).
    private func startKeepAlive() {   // on queue
        keepAliveTimer?.cancel()
        kaTick = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 8)
        t.setEventHandler { [weak self] in
            guard let self, let out = self.out else { return }
            out.keepAlive()
            self.kaTick += 1
            if self.kaTick % 3 == 0 { out.ensureStreams() }   // re-open dropped sessions ~every 24 s
        }
        t.resume()
        keepAliveTimer = t
    }

    private func teardown() {   // on queue
        keepAliveTimer?.cancel(); keepAliveTimer = nil
        stream?.stopCapture(completionHandler: { _ in }); stream = nil
        out?.closeStream(); out = nil
    }

    private func report(_ running: Bool, _ err: String?) { DispatchQueue.main.async { self.onState?(running, err) } }
    private func reportSource(_ w: Int, _ h: Int) { DispatchQueue.main.async { self.onSource?(w, h) } }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let out = out else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let k = min(1.0, max(0.05, smoothing))

        var previewRGB = 0
        var lumaFollow = -1.0
        var colors: [SyncRegion: Int] = [:]
        for region in out.regions {
            let (rawR, rawG, rawB) = Self.regionAverage(ptr, w, h, bpr, region: region, band: bandFraction)
            let avg = (rawR + rawG + rawB) / 3, boost = saturation
            let r = min(255, max(0, avg + (rawR - avg) * boost))
            let g = min(255, max(0, avg + (rawG - avg) * boost))
            let b = min(255, max(0, avg + (rawB - avg) * boost))
            var s = smoothedByRegion[region] ?? (r, g, b)
            s.r += (r - s.r) * k; s.g += (g - s.g) * k; s.b += (b - s.b) * k
            smoothedByRegion[region] = s
            let rgb = (Int(s.r) << 16) | (Int(s.g) << 8) | Int(s.b)
            colors[region] = rgb
            out.streamRegion(region, rgb: rgb)
            if region == .top || previewRGB == 0 { previewRGB = rgb }
            if region == .top || lumaFollow < 0 { lumaFollow = (0.299 * rawR + 0.587 * rawG + 0.114 * rawB) / 255 }
        }

        frameCount += 1
        if frameCount % 3 == 0 {
            let p = previewRGB, c = colors
            DispatchQueue.main.async { self.onColor?(p); self.onRegionColors?(c) }
        }
        if frameCount % 10 == 0, lumaFollow >= 0 { let l = lumaFollow; DispatchQueue.main.async { self.onLuma?(l) } }
    }

    private static func regionAverage(_ ptr: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ bpr: Int,
                                      region: SyncRegion, band: Double) -> (Double, Double, Double) {
        let bw = max(1, Int(Double(w) * band)), bh = max(1, Int(Double(h) * band))
        var x0 = 0, x1 = w, y0 = 0, y1 = h
        switch region {
        case .top:    y1 = bh
        case .bottom: y0 = h - bh
        case .left:   x1 = bw
        case .right:  x0 = w - bw
        case .full:   break
        }
        var rs = 0.0, gs = 0.0, bs = 0.0, n = 0.0
        var y = y0
        while y < y1 {
            let row = y * bpr
            var x = x0
            while x < x1 {
                let p = row + x * 4
                bs += Double(ptr[p]); gs += Double(ptr[p + 1]); rs += Double(ptr[p + 2]) // BGRA
                n += 1; x += 1
            }
            y += 1
        }
        guard n > 0 else { return (0, 0, 0) }
        return (rs / n, gs / n, bs / n)
    }
}
