import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import YeelightKit

enum SyncRegion: String, Hashable, CaseIterable { case top, bottom, left, right, full }

struct SyncTarget { let ip: String; let port: UInt16; let method: String; let region: SyncRegion }

/// Fans colour out to one or more lamps, each with its own UDP session and screen region.
final class SyncOutput {
    let targets: [(device: YeelightDevice, region: SyncRegion)]
    init(_ ts: [SyncTarget]) {
        targets = ts.map { t in
            let d = YeelightDevice(ip: t.ip, tcpPort: t.port)
            d.streamMethod = t.method
            return (d, t.region)
        }
    }
    var regions: Set<SyncRegion> { Set(targets.map { $0.region }) }
    func openStream() { targets.forEach { _ = try? $0.device.openStream() } }
    func stream(rgb: Int) { targets.forEach { $0.device.stream(rgb: rgb) } }            // music: same to all
    func streamRegion(_ region: SyncRegion, rgb: Int) {                                  // screen: per region
        for t in targets where t.region == region { t.device.stream(rgb: rgb) }
    }
    func keepAlive() { targets.forEach { $0.device.keepAlive() } }
    func closeStream() { targets.forEach { $0.device.closeStream() } }
}

/// Ambilight engine: captures the display via ScreenCaptureKit and streams the
/// representative colour of each target's screen region to that target's lamp.
final class ScreenSyncEngine: NSObject, SCStreamOutput {
    var onState: ((Bool, String?) -> Void)?
    var onColor: ((Int) -> Void)?
    var onSource: ((Int, Int) -> Void)?
    var bandFraction: Double = 0.25
    var smoothing: Double = 0.35
    var saturation: Double = 1.25
    var onLuma: ((Double) -> Void)?

    private var stream: SCStream?
    private var out: SyncOutput?
    private let queue = DispatchQueue(label: "yeelightbar.screensync")
    private var smoothedByRegion: [SyncRegion: (r: Double, g: Double, b: Double)] = [:]
    private var lastKeepAlive = Date.distantPast
    private var frameCount = 0

    func start(targets: [SyncTarget]) {
        frameCount = 0
        smoothedByRegion = [:]
        let o = SyncOutput(targets)
        queue.async { self.out = o; o.openStream() }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.onState?(false, "Нет доступа к захвату экрана. Разреши «Запись экрана» и перезапусти приложение.")
                }
                return
            }
            guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content?.displays.first else {
                DispatchQueue.main.async { self.onState?(false, "Не найден дисплей для захвата.") }
                return
            }
            DispatchQueue.main.async { self.onSource?(display.width, display.height) }

            let capW = 128
            let aspect = display.width > 0 ? Double(display.height) / Double(display.width) : 0.5625
            let capH = max(8, Int((Double(capW) * aspect).rounded()))
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
                DispatchQueue.main.async { self.onState?(false, "addStreamOutput: \(error.localizedDescription)") }
                return
            }
            stream.startCapture { err in
                if let err {
                    DispatchQueue.main.async { self.onState?(false, "Не удалось начать захват: \(err.localizedDescription).") }
                } else {
                    self.stream = stream
                    DispatchQueue.main.async { self.onState?(true, nil) }
                }
            }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        queue.async { self.out?.closeStream(); self.out = nil }
    }

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
            out.streamRegion(region, rgb: rgb)
            if region == .top || previewRGB == 0 { previewRGB = rgb }
            if region == .top || lumaFollow < 0 { lumaFollow = (0.299 * rawR + 0.587 * rawG + 0.114 * rawB) / 255 }
        }

        frameCount += 1
        if frameCount % 3 == 0 { let p = previewRGB; DispatchQueue.main.async { self.onColor?(p) } }
        if frameCount % 10 == 0, lumaFollow >= 0 { let l = lumaFollow; DispatchQueue.main.async { self.onLuma?(l) } }
        if Date().timeIntervalSince(lastKeepAlive) > 8 { out.keepAlive(); lastKeepAlive = Date() }
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
