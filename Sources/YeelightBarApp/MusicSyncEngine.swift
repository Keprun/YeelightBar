import Foundation
import ScreenCaptureKit
import CoreMedia
import YeelightKit

enum MusicStyle: Hashable { case beat, spectrum }

/// Music mode: captures system audio via ScreenCaptureKit, splits it into
/// bass / mid / treble with one-pole IIR filters, and drives the lamp's ambient.
///  - .beat     → brightness pumps on the bass/kick, hue drifts.
///  - .spectrum → R = bass, G = mid, B = treble (live colour visualiser).
///
/// Same lifecycle invariant as ScreenSyncEngine: stream/out/generation/filter-state are
/// touched only on `queue`; async setup callbacks hop back onto `queue` and re-check
/// `generation` so a late startCapture can't resurrect a torn-down audio capture.
final class MusicSyncEngine: NSObject, SCStreamOutput {
    var onState: ((Bool, String?) -> Void)?
    var onColor: ((Int) -> Void)?
    var sensitivity = 4.0
    var style: MusicStyle = .beat

    private var stream: SCStream?
    private var out: SyncOutput?
    private let queue = DispatchQueue(label: "yeelightbar.musicsync")
    private var keepAliveTimer: DispatchSourceTimer?
    private var kaTick = 0
    private var generation = 0

    // continuous filter state (across buffers) — touched only on `queue`
    private var lp1 = 0.0   // low-pass ~200 Hz → bass
    private var lp2 = 0.0   // low-pass ~2 kHz → bass+mid
    private var bassPeak = 0.0
    private var level = 0.0
    private var display = 0.0
    private var rBand = 0.0, gBand = 0.0, bBand = 0.0
    private var hue = 0.0
    private var lastStream = Date.distantPast
    private var tick = 0

    func start(targets: [SyncTarget]) {
        queue.async {
            self.generation += 1
            let gen = self.generation
            self.resetFilters()
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

    private func beginCapture(gen: Int) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                guard gen == self.generation else { return }
                if error != nil {
                    self.teardown(); self.report(false, "Нет доступа к захвату. Разреши «Запись экрана» и перезапусти."); return
                }
                guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content?.displays.first else {
                    self.teardown(); self.report(false, "Нет дисплея для аудио-сессии."); return
                }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                do {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                } catch {
                    self.teardown(); self.report(false, "audio output: \(error.localizedDescription)"); return
                }
                stream.startCapture { err in
                    self.queue.async {
                        guard gen == self.generation else { stream.stopCapture(completionHandler: { _ in }); return }
                        if let err {
                            self.teardown(); self.report(false, "Не удалось начать: \(err.localizedDescription)")
                        } else {
                            self.stream = stream
                            self.report(true, nil)
                        }
                    }
                }
            }
        }
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
        stream?.stopCapture(completionHandler: { _ in }); stream = nil
        out?.closeStream(); out = nil
    }

    private func resetFilters() {   // on queue
        lp1 = 0; lp2 = 0; bassPeak = 0; level = 0; display = 0
        rBand = 0; gBand = 0; bBand = 0; hue = 0; lastStream = .distantPast; tick = 0
    }

    private func report(_ running: Bool, _ err: String?) { DispatchQueue.main.async { self.onState?(running, err) } }

    // MARK: - SCStreamOutput (audio)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let out = out else { return }

        var bassSum = 0.0, midSum = 0.0, trebleSum = 0.0, n = 0.0
        let a1 = 0.026, a2 = 0.23   // ~200 Hz and ~2 kHz at 48 kHz
        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                guard let buf = abl.first, let mData = buf.mData else { return }
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { return }
                let ptr = mData.assumingMemoryBound(to: Float.self)
                let ch = max(1, Int(buf.mNumberChannels))
                var i = 0
                while i < count {
                    let x = ch >= 2 ? (Double(ptr[i]) + Double(ptr[i + 1])) * 0.5 : Double(ptr[i]) // mono mix
                    lp1 += a1 * (x - lp1)
                    lp2 += a2 * (x - lp2)
                    let bass = lp1, mid = lp2 - lp1, treble = x - lp2
                    bassSum += bass * bass; midSum += mid * mid; trebleSum += treble * treble
                    n += 1
                    i += ch
                }
            }
        } catch { return }
        guard n > 0 else { return }

        let bassRMS = (bassSum / n).squareRoot()
        let midRMS = (midSum / n).squareRoot()
        let trebleRMS = (trebleSum / n).squareRoot()

        bassPeak = max(bassPeak, min(1.0, bassRMS * sensitivity))
        rBand += (min(1.0, bassRMS * sensitivity)        - rBand) * 0.45
        gBand += (min(1.0, midRMS * sensitivity * 1.6)   - gBand) * 0.45
        bBand += (min(1.0, trebleRMS * sensitivity * 2.6) - bBand) * 0.45

        let now = Date()
        guard now.timeIntervalSince(lastStream) >= 0.05 else { return }   // ~20 Hz
        lastStream = now

        let rgb: Int
        switch style {
        case .beat:
            let target = bassPeak; bassPeak = 0
            level = max(target, level * 0.55)           // POP on the kick, fade ~0.25 s
            display += (level - display) * 0.55
            hue += 0.003 + display * 0.02
            if hue > 1 { hue -= 1 }
            rgb = Self.hsv(hue, 1.0, 0.18 + 0.82 * display)
        case .spectrum:
            var r = rBand, g = gBand, b = bBand
            let mx = max(r, max(g, b))
            if mx < 0.18 { let s = 0.18 / max(mx, 0.001); r *= s; g *= s; b *= s }   // lift when quiet
            rgb = (Int(min(255, r * 255)) << 16) | (Int(min(255, g * 255)) << 8) | Int(min(255, b * 255))
        }
        out.stream(rgb: rgb)

        tick += 1
        if tick % 3 == 0 { DispatchQueue.main.async { self.onColor?(rgb) } }
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> Int {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
    }
}
