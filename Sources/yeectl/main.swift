import Foundation
import YeelightKit

func usage() {
    print("""
    yeectl — Yeelight LAN control / stream test
    Usage:
      yeectl discover                           (SSDP)
      yeectl scan                               (active subnet scan)
      yeectl auto                               (SSDP, fallback to scan)
      yeectl check   <ip>                       (validate a manual IP)
      yeectl state   <ip>
      yeectl on      <ip>
      yeectl off     <ip>
      yeectl bright  <ip> <0-100>
      yeectl ct      <ip> <kelvin 1700-6500>
      yeectl rgb     <ip> <hex e.g. FF8800>     (ambient / bg channel)
      yeectl rainbow <ip> [seconds]             (UDP 20Hz streaming test)
      yeectl seg     <ip> [count] [seconds]     (addressable strip: music-mode segment rainbow)
    """)
}

func hsv2rgb(_ h: Double, _ s: Double, _ v: Double) -> Int {
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

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(1) }
let cmd = args[1]

if cmd == "discover" || cmd == "scan" || cmd == "auto" {
    let devs: [DiscoveredDevice]
    switch cmd {
    case "scan": print("scanning subnet…"); devs = YeelightDiscovery.scan()
    case "auto": devs = YeelightDiscovery.auto(timeout: 2.0)
    default: devs = YeelightDiscovery.discover(timeout: 2.0)
    }
    if devs.isEmpty { print("no Yeelight devices found") }
    for d in devs {
        let mdl = d.model.isEmpty ? "yeelight" : d.model
        let fw = d.fwVer.isEmpty ? "" : "  fw\(d.fwVer)"
        let id = d.id.isEmpty ? "" : "  id=\(d.id)"
        let nm = d.name.isEmpty ? "" : "  name=\(d.name)"
        let via = d.fields["via"] == "scan" ? "  (via scan)" : ""
        print("  \(d.ip):\(d.port)  \(mdl)\(fw)\(id)\(nm)\(via)")
    }
    exit(0)
}

guard args.count >= 3 else { usage(); exit(1) }
let dev = YeelightDevice(ip: args[2])

do {
    switch cmd {
    case "state":
        let names = ["power", "bright", "ct", "color_mode", "bg_power", "bg_bright", "bg_rgb"]
        for (k, v) in zip(names, try dev.properties(names)) { print("  \(k): \(v)") }

    case "check":
        print(YeelightDiscovery.validate(ip: args[2]) != nil
              ? "✓ Yeelight reachable at \(args[2])"
              : "✗ no Yeelight at \(args[2])")

    case "on":  print(try dev.power(true))
    case "off": print(try dev.power(false))

    case "bright":
        guard args.count >= 4, let b = Int(args[3]) else { usage(); exit(1) }
        print(try dev.setBrightness(b))

    case "ct":
        guard args.count >= 4, let k = Int(args[3]) else { usage(); exit(1) }
        print(try dev.setColorTemp(k))

    case "rgb":
        guard args.count >= 4, let rgb = Int(args[3], radix: 16) else { usage(); exit(1) }
        print(try dev.setAmbientRGB(rgb))

    case "rainbow":
        let secs = (args.count >= 4 ? Double(args[3]) : nil) ?? 6
        let before = (try? dev.properties(["bg_rgb"]))?.first.flatMap { Int($0) }
        let token = try dev.openStream()
        print("token \(token) — streaming \(secs)s @ ~20Hz over UDP …")
        let start = Date()
        var frames = 0, lastKA = start
        while Date().timeIntervalSince(start) < secs {
            let t = Date().timeIntervalSince(start)
            dev.stream(rgb: hsv2rgb((t * 0.3).truncatingRemainder(dividingBy: 1.0), 1, 1))
            frames += 1
            if Date().timeIntervalSince(lastKA) >= 5 { dev.keepAlive(); lastKA = Date() }
            usleep(50_000) // 20 Hz
        }
        dev.closeStream()
        print("streamed \(frames) frames (~\(Int(Double(frames) / secs)) Hz)")
        _ = try? dev.setAmbientRGB(before ?? 0xE30DFF) // restore
        print("restored ambient")

    case "seg":
        let n = (args.count >= 4 ? Int(args[3]) : nil) ?? 12
        let secs = (args.count >= 5 ? Double(args[4]) : nil) ?? 15
        guard let myip = YeelightMusicSession.localLANAddress() else { print("no LAN IPv4 found"); exit(1) }
        let sess = YeelightMusicSession(deviceIP: args[2], localIP: myip)
        sess.start()
        print("music session → \(args[2]) from \(myip): \(n) segments, \(secs)s flowing rainbow…")
        let t0 = Date()
        while !sess.isConnected && Date().timeIntervalSince(t0) < 6 { usleep(100_000) }
        print(sess.isConnected ? "  lamp connected ✓" : "  not yet connected (will keep retrying)")
        let start = Date(); var frames = 0
        while Date().timeIntervalSince(start) < secs {
            let phase = Date().timeIntervalSince(start) * 0.15
            let colors = (0..<n).map { i in hsv2rgb((Double(i) / Double(n) + phase).truncatingRemainder(dividingBy: 1.0), 1, 1) }
            sess.sendSegments(colors)
            frames += 1
            usleep(60_000) // ~16 Hz
        }
        sess.stop()
        print("streamed \(frames) segment-frames (~\(Int(Double(frames) / secs)) Hz), session stopped")

    default:
        usage(); exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
