import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Yeelight **music mode** session for addressable strips.
///
/// Per-segment control (`set_segment_rgb`) is silently ignored unless the lamp is in music mode:
/// we open a local TCP server, tell the lamp to connect back to it (`set_music`), and stream
/// commands over that socket. Music mode also bypasses the ~60 cmd/min quota, so it sustains a
/// ~20 Hz segment stream. The lamp drops the connection unpredictably, so this reconnects.
public final class YeelightMusicSession {
    public let deviceIP: String
    private let tcpPort: UInt16
    private let localIP: String
    private let listenPort: UInt16

    private let queue = DispatchQueue(label: "yeelightkit.music")
    private var listenFD: Int32 = -1
    private var connFD: Int32 = -1
    private var running = false
    private var msgId = 1
    private var attempts = 0

    /// `localIP` must be this machine's address on the same LAN as the lamp.
    public init(deviceIP: String, localIP: String, tcpPort: UInt16 = 55443, listenPort: UInt16 = 0) {
        self.deviceIP = deviceIP
        self.localIP = localIP
        self.tcpPort = tcpPort
        self.listenPort = listenPort == 0 ? UInt16(54300 + Int.random(in: 0...600)) : listenPort
    }

    public var isConnected: Bool { queue.sync { connFD >= 0 } }

    deinit {
        // best-effort: don't leave the lamp stuck in music mode or leak fds
        if connFD >= 0 { close(connFD) }
        if listenFD >= 0 { close(listenFD) }
        _ = try? Self.quickCommand(ip: deviceIP, port: tcpPort, method: "set_music", params: [0])
    }

    /// Open the listener and bring the lamp into music mode (connecting back to us). Non-blocking.
    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            attempts = 0
            openListener()
            beginConnect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            if connFD >= 0 { close(connFD); connFD = -1 }
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            _ = try? Self.quickCommand(ip: deviceIP, port: tcpPort, method: "set_music", params: [0])
        }
    }

    /// Stream one frame of segment colours: a flat array of 0xRRGGBB, one per segment.
    public func sendSegments(_ rgb: [Int]) {
        queue.async { [self] in
            guard connFD >= 0 else { return }
            let params = rgb.map { $0 & 0xFFFFFF }
            send(method: "set_segment_rgb", params: params)
        }
    }

    /// Whole-strip colour over the same fast channel (useful as a fallback / non-segment frame).
    public func sendWhole(_ rgb: Int) {
        queue.async { [self] in
            guard connFD >= 0 else { return }
            send(method: "set_rgb", params: [rgb & 0xFFFFFF, "sudden", 0])
        }
    }

    // MARK: - internals (all on `queue`)

    /// Open a NON-BLOCKING listen socket once.
    private func openListener() {
        guard listenFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return }
        let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        listenFD = fd
    }

    /// Non-blocking accept loop: polls briefly (so stop()/sends are never stalled), re-asking the
    /// lamp to dial back every ~3 s, until it connects. Re-schedules itself on `queue`.
    private func beginConnect() {
        guard running, connFD < 0 else { return }
        if listenFD < 0 { openListener() }
        guard listenFD >= 0 else { queue.asyncAfter(deadline: .now() + 1.0) { [self] in beginConnect() }; return }
        if attempts % 15 == 0 {   // re-assert music mode every ~3 s (15 × 200 ms), not on every poll
            _ = try? Self.quickCommand(ip: deviceIP, port: tcpPort, method: "set_music", params: [1, localIP, Int(listenPort)])
        }
        attempts += 1
        var fds = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        if poll(&fds, 1, 200) > 0 {
            let fd = accept(listenFD, nil, nil)
            if fd >= 0 {
                connFD = fd
                var nodelay: Int32 = 1
                setsockopt(connFD, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
                attempts = 0
                return
            }
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [self] in beginConnect() }
    }

    private func send(method: String, params: [Any]) {
        let obj: [String: Any] = ["id": msgId, "method": method, "params": params]
        msgId &+= 1; if msgId < 0 { msgId = 1 }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(contentsOf: [0x0d, 0x0a])
        let n = data.withUnsafeBytes { Darwin.send(connFD, $0.baseAddress, data.count, 0) }
        if n <= 0 { close(connFD); connFD = -1; if running { beginConnect() } }   // lamp dropped us → reconnect
    }

    /// One-off TCP JSON command on a throwaway socket (for set_music on/off).
    @discardableResult
    static func quickCommand(ip: String, port: UInt16, method: String, params: [Any]) throws -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return false }
        let obj: [String: Any] = ["id": 1, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        data.append(contentsOf: [0x0d, 0x0a])
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
        return true
    }

    /// This machine's IPv4 on a private LAN (best-effort) — pass to `init(localIP:)`.
    public static func localLANAddress() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var p = ifap
        var fallback: String?
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                if String(cString: cur.pointee.ifa_name).hasPrefix("en") { return ip }   // prefer Ethernet/Wi-Fi
                fallback = fallback ?? ip
            }
        }
        return fallback
    }
}
