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
        for d in discover(timeout: timeout) { byIP[d.ip] = d }     // SSDP: rich info (id/model/fw)
        for d in scan() where byIP[d.ip] == nil { byIP[d.ip] = d } // active scan: fill any gaps
        return byIP.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Active scan: probe TCP `port` on every host of the local /24 subnet(s), concurrently.
    public static func scan(port: UInt16 = 55443, connectTimeoutMs: Int32 = 200) -> [DiscoveredDevice] {
        var hosts: [String] = []
        for prefix in localIPv4Subnets() {
            for host in 1...254 { hosts.append("\(prefix)\(host)") }
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
        _ = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

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

        let req = Array("{\"id\":1,\"method\":\"get_prop\",\"params\":[\"name\"]}\r\n".utf8)
        _ = req.withUnsafeBytes { send(fd, $0.baseAddress, req.count, 0) }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let resp = String(decoding: buf[0..<n], as: UTF8.self)
        guard resp.contains("\"id\"") else { return nil } // speaks Yeelight JSON
        return DiscoveredDevice(ip: ip, port: port, id: "", model: "", fwVer: "",
                                name: "", support: [], fields: ["via": "scan"])
    }
}
