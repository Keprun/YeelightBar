import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

extension YeelightDiscovery {

    /// Auto-find for the "autosearch" button: SSDP first (rich info),
    /// fall back to an active subnet scan if SSDP is silent (e.g. flood-lockout).
    public static func auto(timeout: Double = 3.0) -> [DiscoveredDevice] {
        var byIP: [String: DiscoveredDevice] = [:]
        for d in discover(timeout: timeout) { byIP[d.ip] = d }              // SSDP: rich info (id/model/fw)
        // Active scan fills gaps only — don't re-probe lamps SSDP already found, so we open no extra
        // connection to a lamp another client (e.g. Home Assistant) is already holding.
        for d in scan(exclude: Set(byIP.keys)) where byIP[d.ip] == nil { byIP[d.ip] = d }
        return byIP.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Active scan: probe TCP `port` on every host of the local /24 subnet(s), concurrently.
    /// `exclude` skips IPs already known (e.g. from SSDP) so we don't open a redundant connection to them.
    public static func scan(port: UInt16 = 55443, connectTimeoutMs: Int32 = 200,
                            exclude: Set<String> = []) -> [DiscoveredDevice] {
        var hosts: [String] = []
        for prefix in localIPv4Subnets() {
            for host in 1...254 { let ip = "\(prefix)\(host)"; if !exclude.contains(ip) { hosts.append(ip) } }
        }
        guard !hosts.isEmpty else { return [] }

        var results: [DiscoveredDevice] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { idx in
            if let dev = probe(ip: hosts[idx], port: port, timeoutMs: connectTimeoutMs) {
                lock.lock(); results.append(dev); lock.unlock()
            }
        }
        return results.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Validate a manually-entered IP with a bounded timeout. Returns a device iff it speaks Yeelight.
    public static func validate(ip: String, port: UInt16 = 55443, timeoutMs: Int32 = 800) -> DiscoveredDevice? {
        probe(ip: ip, port: port, timeoutMs: timeoutMs)
    }

    // MARK: - internals

    private static func localIPv4Subnets() -> [String] {
        var prefixes: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") else { continue }
            let o = ip.split(separator: ".")
            guard o.count == 4 else { continue }
            let prefix = "\(o[0]).\(o[1]).\(o[2])."
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        return prefixes
    }

    /// Returns a device iff `ip:port` answers the Yeelight JSON protocol, else nil.
    private static func probe(ip: String, port: UInt16, timeoutMs: Int32) -> DiscoveredDevice? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return nil } // reject malformed IP

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let cr = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if cr != 0 && errno != EINPROGRESS { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, nfds_t(1), timeoutMs) > 0 else { return nil }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        guard soErr == 0 else { return nil }
        _ = fcntl(fd, F_SETFL, flags) // restore blocking

        var rtv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))

        // Ask for name + model + bg_power in one round-trip. bg_power answers non-empty only on
        // bg-capable lamps (e.g. the Screen Light Bar Pro / lamp15); a plain RGB strip returns "".
        // This lets us pick the right UDP stream method (bg_set_rgb vs set_rgb) for scan/manual
        // devices, which otherwise have an empty SSDP support list.
        let req = Array("{\"id\":1,\"method\":\"get_prop\",\"params\":[\"name\",\"model\",\"bg_power\"]}\r\n".utf8)
        _ = req.withUnsafeBytes { send(fd, $0.baseAddress, req.count, 0) }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let resp = String(decoding: buf[0..<n], as: UTF8.self)
        guard let result = resultArray(resp) else {
            guard resp.contains("\"id\"") else { return nil } // still accept anything that speaks Yeelight JSON
            return DiscoveredDevice(ip: ip, port: port, id: "", model: "", fwVer: "",
                                    name: "", support: [], fields: ["via": "scan"])
        }
        let name = result.count > 0 ? result[0] : ""
        let model = result.count > 1 ? result[1] : ""
        let bgPower = result.count > 2 ? result[2] : ""
        let support = bgPower.isEmpty ? [] : ["bg_set_rgb"]   // bg_power present ⇒ ambient/bg channel exists
        return DiscoveredDevice(ip: ip, port: port, id: "", model: model, fwVer: "",
                                name: name, support: support, fields: ["via": "scan"])
    }

    /// Extract the JSON-RPC "result" array (as strings) from a possibly multi-line response.
    private static func resultArray(_ resp: String) -> [String]? {
        for line in resp.split(whereSeparator: { $0.isNewline }) {   // .isNewline matches the \r\n grapheme
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let result = obj["result"] as? [Any] else { continue }
            return result.map { "\($0)" }
        }
        return nil
    }
}
