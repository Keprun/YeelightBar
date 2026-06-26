import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct YeelightError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Minimal Yeelight LAN client.
///
/// Two transports, both decoded from the official Yeelight-Chroma-Connector:
///  - classic JSON commands over **TCP 55443** (power, brightness, CT, ambient RGB, …)
///  - a low-latency **UDP 55444** streaming session (token handshake) for screen sync.
public final class YeelightDevice {
    public let ip: String
    public let tcpPort: UInt16
    public let udpPort: UInt16

    private var msgId: Int = 1
    private let idLock = NSLock()
    private func nextId() -> Int {
        idLock.lock(); defer { idLock.unlock() }
        let id = msgId
        msgId &+= 1
        if msgId < 0 { msgId = 1 }
        return id
    }

    // UDP streaming session state
    private var udpFD: Int32 = -1
    private var udpAddr = sockaddr_in()
    public private(set) var streamToken: String?
    /// UDP stream method: "bg_set_rgb" for bg/ambient devices, "set_rgb" for plain RGB strips.
    public var streamMethod = "bg_set_rgb"

    public init(ip: String, tcpPort: UInt16 = 55443, udpPort: UInt16 = 55444) {
        self.ip = ip
        self.tcpPort = tcpPort
        self.udpPort = udpPort
    }

    deinit { closeStream() }

    // MARK: - Low-level helpers

    private func makeAddr(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        return addr
    }

    private func setRecvTimeout(_ fd: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds),
                         tv_usec: __darwin_suseconds_t((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func jsonLine(method: String, params: [Any], token: String? = nil, id: Int? = nil) -> Data {
        var obj: [String: Any] = ["id": id ?? nextId(), "method": method, "params": params]
        if let token { obj["token"] = token }
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        data.append(contentsOf: [0x0d, 0x0a]) // CRLF terminator required by the lamp
        return data
    }

    // MARK: - TCP control (request / response)

    @discardableResult
    public func control(_ method: String, _ params: [Any] = [], readTimeout: Double = 0.8) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw YeelightError(message: "socket() failed") }
        defer { close(fd) }

        var addr = makeAddr(port: tcpPort)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            throw YeelightError(message: "connect \(ip):\(tcpPort) failed: \(String(cString: strerror(errno)))")
        }
        setRecvTimeout(fd, readTimeout)

        let reqId = nextId()
        let payload = jsonLine(method: method, params: params, id: reqId)
        _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }

        // TCP is a byte stream and the lamp interleaves unsolicited {"method":"props",…}
        // notifications with replies. Consume complete CRLF-delimited lines and return only
        // the one whose "id" matches the request — skip async pushes / stale replies.
        func crlf(_ a: [UInt8]) -> Int? {
            guard a.count >= 2 else { return nil }
            for i in 0..<(a.count - 1) where a[i] == 0x0D && a[i + 1] == 0x0A { return i }
            return nil
        }
        var acc = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            while let i = crlf(acc) {
                let line = String(decoding: acc[0..<i], as: UTF8.self)
                acc.removeFirst(i + 2)                       // drop the line and its CRLF
                if let id = Self.replyId(line), id == reqId { return line }
                // otherwise: a props notification or stale reply — keep reading
            }
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            acc.append(contentsOf: buf[0..<n])
            if acc.count > 65536 { break }
        }
        // No id-matched reply arrived within the timeout — best effort.
        return String(decoding: acc, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The integer "id" of a JSON-RPC line, or nil for notifications (which carry "method", no "id").
    private static func replyId(_ line: String) -> Int? {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["id"] as? Int
    }

    @discardableResult
    public func power(_ on: Bool, effect: String = "smooth", duration: Int = 300) throws -> String {
        try control("set_power", [on ? "on" : "off", effect, duration])
    }

    @discardableResult
    public func setBrightness(_ pct: Int, effect: String = "smooth", duration: Int = 300) throws -> String {
        try control("set_bright", [max(1, min(100, pct)), effect, duration])
    }

    @discardableResult
    public func setColorTemp(_ kelvin: Int, effect: String = "smooth", duration: Int = 300) throws -> String {
        try control("set_ct_abx", [max(1700, min(6500, kelvin)), effect, duration])
    }

    /// Ambient (background) RGB — the colourful channel on the Screen Light Bar Pro.
    @discardableResult
    public func setAmbientRGB(_ rgb: Int, effect: String = "smooth", duration: Int = 300) throws -> String {
        try control("bg_set_rgb", [rgb & 0xFFFFFF, effect, duration])
    }

    public func properties(_ names: [String]) throws -> [String] {
        let resp = try control("get_prop", names)
        guard let d = resp.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let result = obj["result"] as? [Any] else { return [] }
        return result.map { "\($0)" }
    }

    // MARK: - Addressable strip: direct per-pixel mode (strip8)

    /// Switch an addressable strip into "direct" FX mode — required before `updateLEDs`. Direct mode
    /// silently expires ~25 s after activation, so re-send it periodically while streaming. Returns the
    /// raw reply; classify it with `Self.replyOK(_:)` / `Self.replyError(_:)` — strip8 does NOT advertise
    /// this method in SSDP and may answer `-1 "method not supported"`, so probe it before relying on it.
    @discardableResult
    public func activateDirectMode() throws -> String {
        try control("activate_fx_mode", [["mode": "direct"]])
    }

    /// One per-pixel frame for a strip already in direct mode: `pixels` is one 0xRRGGBB per LED in
    /// physical order. Returns the raw reply (see `Self.replyOK(_:)`).
    @discardableResult
    public func updateLEDs(_ pixels: [Int]) throws -> String {
        try control("update_leds", [Self.packLEDs(pixels)])
    }

    /// Pack one 0xRRGGBB-per-LED frame into the base64 wire form `update_leds` expects. Equivalent to
    /// the Python reference's per-LED `b64encode(bytes([r,g,b]))` concatenation: N LEDs = 3N bytes,
    /// always a multiple of 3, so base64 of the whole buffer carries no interior padding and matches
    /// the 4-chars-per-LED concatenation exactly.
    public static func packLEDs(_ pixels: [Int]) -> String {
        var bytes = [UInt8](); bytes.reserveCapacity(pixels.count * 3)
        for p in pixels {
            bytes.append(UInt8((p >> 16) & 0xFF))
            bytes.append(UInt8((p >> 8) & 0xFF))
            bytes.append(UInt8(p & 0xFF))
        }
        return Data(bytes).base64EncodedString()
    }

    /// True iff `reply` is a JSON-RPC success (`"result":[...]`). Distinguishes a real "ok" from an
    /// error reply OR an empty/timed-out read (both return false) — use to decide if a method works.
    public static func replyOK(_ reply: String) -> Bool {
        guard let d = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return obj["result"] != nil
    }

    /// JSON-RPC error text if `reply` is an `{"error":{…}}` response, else nil (success / notification /
    /// junk). Use to read the "-1 method not supported" a strip returns when it rejects `update_leds`.
    public static func replyError(_ reply: String) -> String? {
        guard let d = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        let code = err["code"].map { "\($0)" } ?? "?"
        let msg = err["message"] as? String ?? "error"
        return "\(msg) (code \(code))"
    }

    // MARK: - UDP streaming session (screen-sync transport)

    /// Opens the UDP session and acquires the streaming token. Call before `stream(rgb:)`.
    @discardableResult
    public func openStream(timeout: Double = 2.0) throws -> String {
        closeStream()
        udpFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpFD >= 0 else { throw YeelightError(message: "udp socket() failed") }
        udpAddr = makeAddr(port: udpPort)
        setRecvTimeout(udpFD, timeout)

        sendUDP(jsonLine(method: "udp_sess_new", params: []))

        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(udpFD, &buf, buf.count, 0)
        guard n > 0 else { closeStream(); throw YeelightError(message: "no udp_sess_token (timeout)") }
        let txt = String(decoding: buf[0..<n], as: UTF8.self)
        guard let token = Self.extractToken(txt) else {
            closeStream(); throw YeelightError(message: "token not found in: \(txt)")
        }
        streamToken = token
        return token
    }

    /// Streams an instant ambient colour (fire-and-forget). Drive at ~20 Hz for sync.
    public func stream(rgb: Int) {
        guard let token = streamToken, udpFD >= 0 else { return }
        sendUDP(jsonLine(method: streamMethod, params: [rgb & 0xFFFFFF, "sudden", 0], token: token))
    }

    /// Keep-alive; call roughly every 10 s while a stream is open.
    public func keepAlive() {
        guard let token = streamToken, udpFD >= 0 else { return }
        sendUDP(jsonLine(method: "udp_sess_keep_alive", params: ["keeplive_interval", "10"], token: token))
    }

    public func closeStream() {
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
        streamToken = nil
    }

    private func sendUDP(_ data: Data) {
        _ = withUnsafePointer(to: &udpAddr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                data.withUnsafeBytes { bp in
                    sendto(udpFD, bp.baseAddress, data.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func extractToken(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let params = obj["params"] as? [String: Any],
           let token = params["token"] as? String {
            return token
        }
        // fallback scan: ..."token":"<value>"...
        guard let r = trimmed.range(of: #""token""#) else { return nil }
        let tail = trimmed[r.upperBound...]
        guard let q1 = tail.range(of: "\"") else { return nil }
        let afterQ1 = tail[q1.upperBound...]
        guard let q2 = afterQ1.range(of: "\"") else { return nil }
        return String(afterQ1[..<q2.lowerBound])
    }
}
