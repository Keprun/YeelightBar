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
    var segments: Int = 0       // 0 = whole-strip (one colour via UDP); >0 = addressable per-segment via music mode
    var reversed: Bool = false  // segment 0 is the far end of the strip
}

/// Fans colour out to one or more lamps. Each lamp is bound to a (display, region). All device
/// socket I/O is serialized on a private queue so it never blocks capture and never races a lamp.
final class SyncOutput {
    private let targets: [(device: YeelightDevice, displayID: CGDirectDisplayID, region: SyncRegion, segments: Int, reversed: Bool)]
    private let io = DispatchQueue(label: "yeelightbar.syncoutput")
    private let music: [String: YeelightMusicSession]   // ip → music session (addressable per-segment targets)

    init(_ ts: [SyncTarget]) {
        let local = YeelightMusicSession.localLANAddress()
        var m: [String: YeelightMusicSession] = [:]
        targets = ts.map { t in
            let d = YeelightDevice(ip: t.ip, tcpPort: t.port)
            d.streamMethod = t.method
            if t.segments > 0, let local { m[t.ip] = YeelightMusicSession(deviceIP: t.ip, localIP: local) }
            return (d, t.displayID, t.region, t.segments, t.reversed)
        }
        music = m
    }
    var isEmpty: Bool { targets.isEmpty }
    var displayIDs: Set<CGDirectDisplayID> { Set(targets.map { $0.displayID }) }
    func regions(on display: CGDirectDisplayID) -> Set<SyncRegion> {
        Set(targets.filter { $0.displayID == display }.map { $0.region })
    }
    /// Highest segment count among addressable targets on (display, region); 0 if none are segmented.
    func maxSegments(on display: CGDirectDisplayID, _ region: SyncRegion) -> Int {
        targets.filter { $0.displayID == display && $0.region == region }.map { $0.segments }.max() ?? 0
    }

    func openStream() {
        io.async { self.targets.forEach { if $0.segments == 0 { _ = try? $0.device.openStream(timeout: 1.5) } } }
        music.values.forEach { $0.start() }
    }
    func ensureStreams() { io.async { self.targets.forEach { if $0.segments == 0, $0.device.streamToken == nil { _ = try? $0.device.openStream(timeout: 0.8) } } } }
    func stream(rgb: Int) {                                  // music(audio): whole-strip via UDP, segmented = solid colour
        io.async { self.targets.forEach { if $0.segments == 0 { $0.device.stream(rgb: rgb) } } }
        music.values.forEach { $0.sendWhole(rgb) }
    }
    func streamRegion(_ display: CGDirectDisplayID, _ region: SyncRegion, rgb: Int) {   // screen: whole-strip targets only
        io.async { for t in self.targets where t.displayID == display && t.region == region && t.segments == 0 { t.device.stream(rgb: rgb) } }
    }
    /// Per-segment screen frame: `slices` = colours along the region (left→right / top→bottom) at the engine's
    /// resolution; resample to each addressable target's own segment count and stream over its music session.
    func streamSegments(_ display: CGDirectDisplayID, _ region: SyncRegion, slices: [Int]) {
        guard !slices.isEmpty else { return }
        for t in targets where t.displayID == display && t.region == region && t.segments > 0 {
            let n = t.segments
            var out = (0..<n).map { i in slices[min(slices.count - 1, i * slices.count / n)] }
            if t.reversed { out.reverse() }
            music[t.device.ip]?.sendSegments(out)
        }
    }
    func keepAlive() { io.async { self.targets.forEach { if $0.segments == 0 { $0.device.keepAlive() } } } }
    func closeStream() {
        io.async { self.targets.forEach { if $0.segments == 0 { $0.device.closeStream() } } }
        music.values.forEach { $0.stop() }
    }
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
    var onRegionColors: (([CGDirectDisplayID: [SyncRegion: Int]]) -> Void)?
    var onLuma: ((Double) -> Void)?
    var bandFraction: Double = 0.25
    var smoothing: Double = 0.35
    var saturation: Double = 1.25

    private var out: SyncOutput?
    private var streamsByDisplay: [CGDirectDisplayID: SCStream] = [:]              // keyed by RESOLVED physical display
    private var displayByStream: [ObjectIdentifier: Set<CGDirectDisplayID>] = [:]  // requested dids each stream serves
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
                    let pid = scd.displayID
                    if let existing = self.streamsByDisplay[pid] {       // same physical screen already captured → reuse it
                        self.displayByStream[ObjectIdentifier(existing), default: []].insert(did)
                        continue
                    }
                    let config = Self.config(for: scd)
                    let stream = SCStream(filter: SCContentFilter(display: scd, excludingApplications: [], exceptingWindows: []),
                                          configuration: config, delegate: nil)
                    do {
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    } catch { continue }
                    self.displayByStream[ObjectIdentifier(stream)] = [did]
                    self.streamsByDisplay[pid] = stream
                    stream.startCapture { err in
                        self.queue.async {
                            guard gen == self.generation else { stream.stopCapture(completionHandler: { _ in }); return }
                            if err != nil {
                                self.streamsByDisplay[pid] = nil
                                self.displayByStream[ObjectIdentifier(stream)] = nil
                                if self.streamsByDisplay.isEmpty {        // every capture failed → unwind, don't zombie
                                    self.teardown(); self.report(false, "Не удалось начать захват экрана.")
                                }
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
              let dids = displayByStream[ObjectIdentifier(stream)],
              let out = out,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let k = min(1.0, max(0.05, smoothing))

        var lumaFollow = -1.0
        // One physical stream can serve several requested display ids (e.g. a lamp pinned to an
        // unplugged screen that fell back to this one). Same pixels → route to each.
        for did in dids {
            let wanted = out.regions(on: did)
            guard !wanted.isEmpty else { continue }
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
                out.streamRegion(did, region, rgb: (Int(s.r) << 16) | (Int(s.g) << 8) | Int(s.b))
                // addressable strips: slice this region along its length and stream per-segment colours
                let segN = out.maxSegments(on: did, region)
                if segN > 0 {
                    let slices = Self.regionSlices(ptr, w, h, bpr, region: region, band: bandFraction, n: max(2, segN), saturation: saturation)
                    out.streamSegments(did, region, slices: slices)
                }
                if lumaFollow < 0 { lumaFollow = (0.299 * rawR + 0.587 * rawG + 0.114 * rawB) / 255 }
            }
            smoothed[did] = sm
        }

        frameCount += 1
        if frameCount % 3 == 0 {
            let snapshot = smoothed.mapValues { $0.mapValues { (Int($0.r) << 16) | (Int($0.g) << 8) | Int($0.b) } }
            DispatchQueue.main.async { self.onRegionColors?(snapshot) }
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

    /// Slice a region into `n` colours along its length: top/bottom/full → left→right columns;
    /// left/right → top→bottom rows. Used to drive addressable strips per-segment.
    private static func regionSlices(_ ptr: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ bpr: Int,
                                     region: SyncRegion, band: Double, n: Int, saturation: Double) -> [Int] {
        let bw = max(1, Int(Double(w) * band)), bh = max(1, Int(Double(h) * band))
        var x0 = 0, x1 = w, y0 = 0, y1 = h
        switch region {
        case .top:    y1 = bh
        case .bottom: y0 = h - bh
        case .left:   x1 = bw
        case .right:  x0 = w - bw
        case .full:   break
        }
        let vertical = (region == .left || region == .right)
        var out = [Int](); out.reserveCapacity(n)
        for s in 0..<n {
            var sx0 = x0, sx1 = x1, sy0 = y0, sy1 = y1
            if vertical { sy0 = y0 + (y1 - y0) * s / n; sy1 = y0 + (y1 - y0) * (s + 1) / n }
            else        { sx0 = x0 + (x1 - x0) * s / n; sx1 = x0 + (x1 - x0) * (s + 1) / n }
            var rs = 0.0, gs = 0.0, bs = 0.0, cnt = 0.0
            var y = sy0
            while y < sy1 {
                let row = y * bpr
                var x = sx0
                while x < sx1 {
                    let p = row + x * 4
                    bs += Double(ptr[p]); gs += Double(ptr[p + 1]); rs += Double(ptr[p + 2])
                    cnt += 1; x += 1
                }
                y += 1
            }
            guard cnt > 0 else { out.append(0); continue }
            var r = rs / cnt, g = gs / cnt, b = bs / cnt
            let avg = (r + g + b) / 3
            r = min(255, max(0, avg + (r - avg) * saturation))
            g = min(255, max(0, avg + (g - avg) * saturation))
            b = min(255, max(0, avg + (b - avg) * saturation))
            out.append((Int(r) << 16) | (Int(g) << 8) | Int(b))
        }
        return out
    }
}
