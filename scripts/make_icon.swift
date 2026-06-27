import AppKit

// Draws the YeelightBar app icon (concept A — light bar + rainbow ambilight bloom) at any size,
// writing a full .iconset. Pure CoreGraphics → crisp from 16 px to 1024 px.

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
            blue: CGFloat(h & 0xff) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let rainbow = [hex(0xFF3B3B), hex(0xFFE600), hex(0x44D62C), hex(0x00D0E0), hex(0x3366FF), hex(0xFF2CB0)]
let rainbowLoc: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]

func draw(_ S: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(S)
    cg.translateBy(x: 0, y: s); cg.scaleBy(x: 1, y: -1)   // top-left origin, y down (matches the SVG)
    func P(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: fx * s, y: fy * s) }
    let r = 0.233 * s
    let squ = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: r, cornerHeight: r, transform: nil)

    cg.saveGState()
    cg.addPath(squ); cg.clip()
    let bg = CGGradient(colorsSpace: space, colors: [hex(0x141A12), hex(0x050805)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: s), options: [])

    let rg = CGGradient(colorsSpace: space, colors: rainbow as CFArray, locations: rainbowLoc)!
    func bloom(_ pts: [CGPoint], _ alpha: CGFloat) {
        let path = CGMutablePath(); path.move(to: pts[0]); pts.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
        cg.saveGState(); cg.addPath(path); cg.clip(); cg.setAlpha(alpha)
        cg.drawLinearGradient(rg, start: .zero, end: CGPoint(x: s, y: 0), options: [])
        cg.restoreGState()
    }
    bloom([P(0.167, 0.633), P(0.833, 0.633), P(0.933, 0.24), P(0.067, 0.24)], 0.30)
    bloom([P(0.267, 0.633), P(0.733, 0.633), P(0.8, 0.333), P(0.2, 0.333)], 0.55)

    let bar = CGRect(x: 0.147 * s, y: 0.64 * s, width: 0.707 * s, height: 0.087 * s)
    cg.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
    cg.setFillColor(hex(0xF2F4EC)); cg.fillPath()
    let glow = CGRect(x: 0.147 * s, y: 0.727 * s, width: 0.707 * s, height: 0.04 * s)
    cg.addPath(CGPath(roundedRect: glow, cornerWidth: glow.height / 2, cornerHeight: glow.height / 2, transform: nil))
    cg.setFillColor(hex(0x44D62C, 0.5)); cg.fillPath()
    cg.restoreGState()

    cg.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: s - 1, height: s - 1), cornerWidth: r, cornerHeight: r, transform: nil))
    cg.setStrokeColor(hex(0x44D62C, 0.32)); cg.setLineWidth(max(1, s * 0.008)); cg.strokePath()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let map: [(Int, [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]
for (sz, names) in map {
    let data = draw(sz)
    for n in names { try! data.write(to: URL(fileURLWithPath: outDir + "/" + n)) }
}
print("wrote iconset → \(outDir)")
