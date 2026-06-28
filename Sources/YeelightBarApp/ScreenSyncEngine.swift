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
    var band: Double = 0.25     // capture DEPTH: fraction of the screen sampled inward from the edge
    var length: Double = 1.0    // capture LENGTH: fraction of the edge sampled along it (1 = the whole edge)
    var center: Double = 0.5    // where that length is centred along the edge (0.5 = middle)
}

/// Per-(display, region) capture geometry the engine reads each frame (depth × length × position).
struct ZoneGeom { var band = 0.25; var length = 1.0; var center = 0.5 }

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
    /// Auxiliary single-region tap (the Keychron keyboard): sampled even when no lamp uses its
    /// (display, region), so the keyboard can ambient off any screen zone. Set before start().
    var auxDisplay: CGDirectDisplayID?
    var auxRegion: SyncRegion = .bottom
    var auxGeom = ZoneGeom()
    var onAuxColor: ((Int) -> Void)?
    private var auxSmoothed: (r: Double, g: Double, b: Double)?
    /// Live per-(display, region) capture geometry. Seeded from the targets at start and updatable
    /// without restarting the capture, so the geometry sliders respond instantly. Touched only on `queue`.
    private var geoms: [CGDirectDisplayID: [SyncRegion: ZoneGeom]] = [:]
    private var smoothing: Double = 0.35      // read on `queue`; mutate only via the setters
    private var saturation: Double = 1.25
    private var snapCuts = false              // snap colour instantly on a big scene cut
    private var skipBlackBars = false         // ignore near-black letterbox/pillarbox pixels when averaging
    func setSmoothing(_ v: Double) { queue.async { self.smoothing = v } }
    func setSaturation(_ v: Double) { queue.async { self.saturation = v } }
    func setSnapCuts(_ v: Bool) { queue.async { self.snapCuts = v } }
    func setSkipBlackBars(_ v: Bool) { queue.async { self.skipBlackBars = v } }

    /// EMA blend toward a new colour; on a large delta (a scene cut), `snap` jumps most of the way at once.
    private static func blend(_ s: inout (r: Double, g: Double, b: Double), _ r: Double, _ g: Double, _ b: Double, k: Double, snap: Bool) {
        var kk = k
        if snap, abs(r - s.r) + abs(g - s.g) + abs(b - s.b) > 140 { kk = max(kk, 0.85) }
        s.r += (r - s.r) * kk; s.g += (g - s.g) * kk; s.b += (b - s.b) * kk
    }

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
            self.auxSmoothed = nil
            let o = SyncOutput(targets)
            self.out = o
            self.geoms = Self.geomMap(targets)
            o.openStream()
            self.startKeepAlive()
            self.beginCapture(gen: gen, displays: o.displayIDs.union(self.auxDisplay.map { [$0] } ?? []))
        }
    }

    func stop() {
        queue.async { self.generation += 1; self.teardown() }
    }

    /// Update capture geometry live (slider drag) — no stream restart, no flicker.
    func setGeoms(_ m: [CGDirectDisplayID: [SyncRegion: ZoneGeom]]) { queue.async { self.geoms = m } }

    /// Set the keyboard aux tap. Region/geom apply live; a display change needs a restart to re-capture.
    func setAux(display: CGDirectDisplayID?, region: SyncRegion, geom: ZoneGeom) {
        queue.async { self.auxDisplay = display; self.auxRegion = region; self.auxGeom = geom }
    }

    /// Collapse targets to one geometry per (display, region).
    private static func geomMap(_ ts: [SyncTarget]) -> [CGDirectDisplayID: [SyncRegion: ZoneGeom]] {
        var m: [CGDirectDisplayID: [SyncRegion: ZoneGeom]] = [:]
        for t in ts { m[t.displayID, default: [:]][t.region] = ZoneGeom(band: t.band, length: t.length, center: t.center) }
        return m
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

        // One physical stream can serve several requested display ids (e.g. a lamp pinned to an
        // unplugged screen that fell back to this one). Same pixels → route to each.
        for did in dids {
            // keyboard aux tap — computed even on a display no lamp samples
            if did == auxDisplay {
                let ag = auxGeom
                let (rr, gg, bb) = Self.regionAverage(ptr, w, h, bpr, region: auxRegion, band: ag.band, length: ag.length, center: ag.center, skipBlack: skipBlackBars)
                let avg = (rr + gg + bb) / 3, boost = saturation
                let r = min(255, max(0, avg + (rr - avg) * boost))
                let gr = min(255, max(0, avg + (gg - avg) * boost))
                let bl = min(255, max(0, avg + (bb - avg) * boost))
                var s = auxSmoothed ?? (r, gr, bl)
                Self.blend(&s, r, gr, bl, k: k, snap: snapCuts)
                auxSmoothed = s
                if frameCount % 2 == 0 {
                    DispatchQueue.main.async { self.onAuxColor?((Int(s.r) << 16) | (Int(s.g) << 8) | Int(s.b)) }
                }
            }
            let wanted = out.regions(on: did)
            guard !wanted.isEmpty else { continue }
            var sm = smoothed[did] ?? [:]
            for region in wanted {
                let geo = geoms[did]?[region] ?? ZoneGeom()
                let (rawR, rawG, rawB) = Self.regionAverage(ptr, w, h, bpr, region: region, band: geo.band, length: geo.length, center: geo.center, skipBlack: skipBlackBars)
                let avg = (rawR + rawG + rawB) / 3, boost = saturation
                let r = min(255, max(0, avg + (rawR - avg) * boost))
                let g = min(255, max(0, avg + (rawG - avg) * boost))
                let b = min(255, max(0, avg + (rawB - avg) * boost))
                var s = sm[region] ?? (r, g, b)
                Self.blend(&s, r, g, b, k: k, snap: snapCuts)
                sm[region] = s
                out.streamRegion(did, region, rgb: (Int(s.r) << 16) | (Int(s.g) << 8) | Int(s.b))
                // addressable strips: slice this region along its length and stream per-segment colours
                let segN = out.maxSegments(on: did, region)
                if segN > 0 {
                    let slices = Self.regionSlices(ptr, w, h, bpr, region: region, band: geo.band, length: geo.length, center: geo.center, n: max(2, segN), saturation: saturation)
                    out.streamSegments(did, region, slices: slices)
                }
            }
            smoothed[did] = sm
        }

        frameCount += 1
        if frameCount % 3 == 0 {
            let snapshot = smoothed.mapValues { $0.mapValues { (Int($0.r) << 16) | (Int($0.g) << 8) | Int($0.b) } }
            DispatchQueue.main.async { self.onRegionColors?(snapshot) }
        }
        // "Brightness follows scene": track the WHOLE frame's average luma, computed deterministically.
        // (Previously it sampled "whichever region the Set yielded first" — with top+bottom regions that
        //  flip-flopped between bright top and dark bottom every frame, jittering the front-white brightness.)
        if frameCount % 10 == 0, onLuma != nil {
            let (fr, fg, fb) = Self.regionAverage(ptr, w, h, bpr, region: .full, band: 1.0)
            let l = (0.299 * fr + 0.587 * fg + 0.114 * fb) / 255
            DispatchQueue.main.async { self.onLuma?(l) }
        }
    }

    /// Pixel bounds of a capture zone: `band` sets DEPTH inward from the edge; `length`/`center`
    /// set the EXTENT and POSITION along the edge (clamped so the window stays on-screen).
    private static func zoneBounds(_ w: Int, _ h: Int, region: SyncRegion,
                                   band: Double, length: Double, center: Double) -> (Int, Int, Int, Int) {
        let bw = max(1, Int(Double(w) * band)), bh = max(1, Int(Double(h) * band))
        var x0 = 0, x1 = w, y0 = 0, y1 = h
        func span(_ total: Int) -> (Int, Int) {
            let len = max(1, min(total, Int(Double(total) * length)))
            let start = max(0, min(Int(Double(total) * center) - len / 2, total - len))
            return (start, start + len)
        }
        switch region {
        case .top:    y1 = bh;     (x0, x1) = span(w)
        case .bottom: y0 = h - bh; (x0, x1) = span(w)
        case .left:   x1 = bw;     (y0, y1) = span(h)
        case .right:  x0 = w - bw; (y0, y1) = span(h)
        case .full:   break
        }
        return (x0, x1, y0, y1)
    }

    private static func regionAverage(_ ptr: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ bpr: Int,
                                      region: SyncRegion, band: Double,
                                      length: Double = 1.0, center: Double = 0.5,
                                      skipBlack: Bool = false) -> (Double, Double, Double) {
        let (x0, x1, y0, y1) = zoneBounds(w, h, region: region, band: band, length: length, center: center)
        var rs = 0.0, gs = 0.0, bs = 0.0, n = 0.0
        var y = y0
        while y < y1 {
            let row = y * bpr
            var x = x0
            while x < x1 {
                let p = row + x * 4
                let b = Double(ptr[p]), g = Double(ptr[p + 1]), r = Double(ptr[p + 2]) // BGRA
                if !skipBlack || r + g + b > 24 { bs += b; gs += g; rs += r; n += 1 }   // drop near-black letterbox pixels
                x += 1
            }
            y += 1
        }
        guard n > 0 else { return (0, 0, 0) }
        return (rs / n, gs / n, bs / n)
    }

    /// Slice a region into `n` colours along its length: top/bottom/full → left→right columns;
    /// left/right → top→bottom rows. Used to drive addressable strips per-segment.
    private static func regionSlices(_ ptr: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ bpr: Int,
                                     region: SyncRegion, band: Double, length: Double, center: Double,
                                     n: Int, saturation: Double) -> [Int] {
        let (x0, x1, y0, y1) = zoneBounds(w, h, region: region, band: band, length: length, center: center)
        let vertical = (region == .left || region == .right)
        // Never make more buckets than the captured span has pixels, else narrow spans (short "Length")
        // would slice into zero-width columns that read as black gaps. Average over m real buckets, then
        // fan out to the requested n segments — each backed by real pixels, no black holes.
        let extent = vertical ? (y1 - y0) : (x1 - x0)
        let m = max(1, min(n, extent))
        var buckets = [Int](); buckets.reserveCapacity(m)
        for s in 0..<m {
            var sx0 = x0, sx1 = x1, sy0 = y0, sy1 = y1
            if vertical { sy0 = y0 + (y1 - y0) * s / m; sy1 = y0 + (y1 - y0) * (s + 1) / m }
            else        { sx0 = x0 + (x1 - x0) * s / m; sx1 = x0 + (x1 - x0) * (s + 1) / m }
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
            guard cnt > 0 else { buckets.append(buckets.last ?? 0); continue }
            var r = rs / cnt, g = gs / cnt, b = bs / cnt
            let avg = (r + g + b) / 3
            r = min(255, max(0, avg + (r - avg) * saturation))
            g = min(255, max(0, avg + (g - avg) * saturation))
            b = min(255, max(0, avg + (b - avg) * saturation))
            buckets.append((Int(r) << 16) | (Int(g) << 8) | Int(b))
        }
        return (0..<n).map { buckets[$0 * m / n] }
    }
}
