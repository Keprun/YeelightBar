import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct DiscoveredDevice {
    public let ip: String
    public let port: UInt16
    public let id: String
    public let model: String
    public let fwVer: String
    public let name: String
    public let support: [String]
    public let fields: [String: String]
}

/// SSDP discovery of Yeelight LAN-Control devices (multicast 239.255.255.250:1982).
public enum YeelightDiscovery {

    public static func discover(timeout: Double = 3.0, retries: Int = 3) -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var ttl: Int32 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = 0
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var grp = sockaddr_in()
        grp.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        grp.sin_family = sa_family_t(AF_INET)
        grp.sin_port = UInt16(1982).bigEndian
        _ = "239.255.255.250".withCString { inet_pton(AF_INET, $0, &grp.sin_addr) }

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n"
        let data = Array(msg.utf8)
        var found: [String: DiscoveredDevice] = [:]
        let start = Date()
        var sends = 0
        var lastSend = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date().timeIntervalSince(start) < timeout {
            // UDP is lossy — resend the M-SEARCH a few times across the window.
            if sends < retries, Date().timeIntervalSince(lastSend) > 0.6 {
                _ = withUnsafePointer(to: &grp) { gp in
                    gp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        data.withUnsafeBytes { bp in
                            sendto(fd, bp.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sends += 1
                lastSend = Date()
            }
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { continue } // recv timeout slice — keep polling until deadline
            if let dev = parse(String(decoding: buf[0..<n], as: UTF8.self)) {
                found[dev.id.isEmpty ? dev.ip : dev.id] = dev
            }
        }
        return Array(found.values)
    }

    private static func parse(_ txt: String) -> DiscoveredDevice? {
        var f: [String: String] = [:]
        for raw in txt.split(whereSeparator: { $0.isNewline }) {
            guard let idx = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = raw[raw.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { f[key] = val }
        }
        guard let loc = f["location"], let r = loc.range(of: "yeelight://") else { return nil }
        let hostPort = loc[r.upperBound...].split(separator: ":")
        let ip = String(hostPort.first ?? "")
        guard !ip.isEmpty else { return nil }
        let port = hostPort.count > 1 ? (UInt16(hostPort[1]) ?? 55443) : 55443
        return DiscoveredDevice(
            ip: ip, port: port,
            id: f["id"] ?? "", model: f["model"] ?? "", fwVer: f["fw_ver"] ?? "",
            name: f["name"] ?? "",
            support: (f["support"] ?? "").split(separator: " ").map(String.init),
            fields: f)
    }
}
