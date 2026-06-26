import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import YeelightKit

enum SyncRegion: String, Hashable, CaseIterable { case top, bottom, left, right, full }

/// One lamp's screen-sync assignment: which display it samples, which region of it, and how to stream.
struct SyncTarget {
    let ip: String
    let port: UInt16
    let method: String
    let region: SyncRegion
    let displayID: CGDirectDisplayID
}

/// Fans colour out to one or more lamps. Each lamp is bound to a (display, region). All device
/// socket I/O is serialized on a private queue so it never blocks capture and never races a lamp.
final class SyncOutput {
    private let targets: [(device: YeelightDevice, displayID: CGDirectDisplayID, region: SyncRegion)]
    private let io = DispatchQueue(label: "yeelightbar.syncoutput")
    init(_ ts: [SyncTarget]) {
        targets = ts.map { t in
            let d = YeelightDevice(ip: t.ip, tcpPort: t.port)
            d.streamMethod = t.method
            return (d, t.displayID, t.region)
        }
    }
    var isEmpty: Bool { targets.isEmpty }
    var displayIDs: Set<CGDirectDisplayID> { Set(targets.map { $0.displayID }) }
    func regions(on display: CGDirectDisplayID) -> Set<SyncRegion> {
        Set(targets.filter { $0.displayID == display }.map { $0.region })
    }

    func openStream() { io.async { self.targets.forEach { _ = try? $0.device.openStream(timeout: 1.5) } } }
    func ensureStreams() { io.async { self.targets.forEach { if $0.device.streamToken == nil { _ = try? $0.device.openStream(timeout: 0.8) } } } }
    func stream(rgb: Int) { io.async { self.targets.forEach { $0.device.stream(rgb: rgb) } } }   // music: same to all
    func streamRegion(_ display: CGDirectDisplayID, _ region: SyncRegion, rgb: Int) {              // screen: per display+region
        io.async { for t in self.targets where t.displayID == display && t.region == region { t.device.stream(rgb: rgb) } }
    }
    func keepAlive() { io.async { self.targets.forEach { $0.device.keepAlive() } } }
    func closeStream() { io.async { self.targets.forEach { $0.device.closeStream() } } }
}

/// Multi-display ambilight engine: opens one ScreenCaptureKit stream per display that has lamps
/// assigned, computes each target's region colour on its own display, and streams it to that lamp.
///
/// Lifecycle invariant: stream maps / out / smoothed / frameCount / keepAliveTimer / generation are
/// touched ONLY on `queue`. start()/stop() enqueue onto it; every sample handler and async setup
/// callback runs on / hops back onto `queue` and re-checks `generation`, so a late callback can't
/// resurrect a torn-down capture.
final class ScreenSyncEngine: NSObject, SCStreamOutput {
    var onState: ((Bool, String?) -> Void)?
    var onColor: ((Int) -> Void)?                                   // primary preview swatch (mini panel)
    var onRegionColors: (([CGDirectDisplayID: [SyncRegion: Int]]) -> Void)?
    var onLuma: ((Double) -> Void)?
    var bandFraction: Double = 0.25
    var smoothing: Double = 0.35
    var saturation: Double = 1.25

    private var out: SyncOutput?
    private var streamsByDisplay: [CGDirectDisplayID: SCStream] = [:]
    private var displayByStream: [ObjectIdentifier: CGDirectDisplayID] = [:]
    private let queue = DispatchQueue(label: "yeelightbar.screensync")
    private var smoothed: [CGDirectDisplayID: [SyncRegion: (r: Double, g: Double, b: Double)]] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    private var kaTick = 0
    private var frameCount = 0
    private var generation = 0

    func start(targets: [SyncTarget]) {
        queue.async {
            self.generation += 1
            let gen = self.generation
            self.frameCount = 0
            self.smoothed = [:]
            let o = SyncOutput(targets)
            self.out = o
            o.openStream()
            self.startKeepAlive()
            self.beginCapture(gen: gen, displays: o.displayIDs)
        }
    }

    func stop() {
        queue.async { self.generation += 1; self.teardown() }
    }

    // MARK: - Capture setup

    private func beginCapture(gen: Int, displays: Set<CGDirectDisplayID>) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                guard gen == self.generation else { return }
                if error != nil {
                    self.teardown()
                    self.report(false, "Нет доступа к захвату экрана. Разреши «Запись экрана» и перезапусти приложение.")
                    return
                }
                guard let content else { self.teardown(); self.report(false, "Не удалось получить список экранов."); return }

                for did in displays {
                    // fall back to the main display if a target's chosen screen was unplugged
                    guard let scd = content.displays.first(where: { $0.displayID == did })
                                 ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                                 ?? content.displays.first else { continue }
                    let config = Self.config(for: scd)
                    let stream = SCStream(filter: SCContentFilter(display: scd, excludingApplications: [], exceptingWindows: []),
                                          configuration: config, delegate: nil)
                    do {
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    } catch { continue }
                    self.displayByStream[ObjectIdentifier(stream)] = did
                    self.streamsByDisplay[did] = stream
                    stream.startCapture { err in
                        self.queue.async {
                            guard gen == self.generation else { stream.stopCapture(completionHandler: { _ in }); return }
                            if err != nil {
                                self.streamsByDisplay[did] = nil
                                self.displayByStream[ObjectIdentifier(stream)] = nil
                            }
                        }
                    }
                }

                if self.streamsByDisplay.isEmpty {
                    self.teardown(); self.report(false, "Не найден дисплей для захвата.")
                } else {
                    self.report(true, nil)
                }
            }
        }
    }

    private static func config(for display: SCDisplay) -> SCStreamConfiguration {
        // Resolution-independent: scale the longer edge to a fixed target, keep the exact aspect.
        let dw = max(1, display.width), dh = max(1, display.height)
        let scale = 192.0 / Double(max(dw, dh))
        func even(_ x: Double) -> Int { let n = max(16, Int(x.rounded())); return n - (n % 2) }
        let config = SCStreamConfiguration()
        config.width = even(Double(dw) * scale)
        config.height = even(Double(dh) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false
        return config
    }

    private func startKeepAlive() {   // on queue
        keepAliveTimer?.cancel()
        kaTick = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 8)
        t.setEventHandler { [weak self] in
            guard let self, let out = self.out else { return }
            out.keepAlive()
            self.kaTick += 1
            if self.kaTick % 3 == 0 { out.ensureStreams() }
        }
        t.resume()
        keepAliveTimer = t
    }

    private func teardown() {   // on queue
        keepAliveTimer?.cancel(); keepAliveTimer = nil
        for (_, s) in streamsByDisplay { s.stopCapture(completionHandler: { _ in }) }
        streamsByDisplay.removeAll(); displayByStream.removeAll()
        out?.closeStream(); out = nil
    }

    private func report(_ running: Bool, _ err: String?) { DispatchQueue.main.async { self.onState?(running, err) } }

    // MARK: - SCStreamOutput (runs on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let did = displayByStream[ObjectIdentifier(stream)],
              let out = out,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let wanted = out.regions(on: did)
        guard !wanted.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let k = min(1.0, max(0.05, smoothing))

        var byRegion: [SyncRegion: Int] = [:]
        var lumaFollow = -1.0
        var sm = smoothed[did] ?? [:]
        for region in wanted {
            let (rawR, rawG, rawB) = Self.regionAverage(ptr, w, h, bpr, region: region, band: bandFraction)
            let avg = (rawR + rawG + rawB) / 3, boost = saturation
            let r = min(255, max(0, avg + (rawR - avg) * boost))
            let g = min(255, max(0, avg + (rawG - avg) * boost))
            let b = min(255, max(0, avg + (rawB - avg) * boost))
            var s = sm[region] ?? (r, g, b)
            s.r += (r - s.r) * k; s.g += (g - s.g) * k; s.b += (b - s.b) * k
            sm[region] = s
            let rgb = (Int(s.r) << 16) | (Int(s.g) << 8) | Int(s.b)
            byRegion[region] = rgb
            out.streamRegion(did, region, rgb: rgb)
            if lumaFollow < 0 { lumaFollow = (0.299 * rawR + 0.587 * rawG + 0.114 * rawB) / 255 }
        }
        smoothed[did] = sm

        frameCount += 1
        if frameCount % 3 == 0 {
            let snapshot = smoothed.mapValues { $0.mapValues { (Int($0.r) << 16) | (Int($0.g) << 8) | Int($0.b) } }
            let preview = byRegion[.top] ?? byRegion.values.first ?? 0
            DispatchQueue.main.async { self.onColor?(preview); self.onRegionColors?(snapshot) }
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
