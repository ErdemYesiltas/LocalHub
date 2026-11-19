import CoreImage
import Foundation

/// The QR payload: exactly what a user could otherwise type, plus the hub's
/// identity. Scanning grants no more trust than typing it.
///
/// v2: `localhub://pair?v=2&u=<https url>&fp=<sha256 hex>&c=<6 digits>&id=<hub id>&n=<hub name>`
/// v1 (ArtBlend Companion, legacy): `artblend-companion://pair?v=1&u=…&fp=…&c=…`
public enum PairingInvite {
    public static func uri(address: String, fingerprint: String, code: String,
                           hubID: String, hubName: String) -> String {
        build(scheme: "localhub", items: [("v", "2"), ("u", address), ("fp", fingerprint), ("c", code),
            ("id", hubID), ("n", String(hubName.prefix(40)))])
    }

    public static func legacyURI(address: String, fingerprint: String, code: String) -> String {
        build(scheme: "artblend-companion", items: [("v", "1"), ("u", address), ("fp", fingerprint), ("c", code)])
    }

    private static func build(scheme: String, items: [(String, String)]) -> String {
        // Encode ":" "/" "?" "&" "=" "+" so the nested URL survives any scanner.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=+")
        let query = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
        return "\(scheme)://pair?" + query.joined(separator: "&")
    }

    /// QR modules, true = dark, without the quiet zone.
    public static func modules(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: &pixels,
            rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
        // CoreImage adds one module of white border; strip it.
        let rows = (0..<height).map { y in (0..<width).map { x in pixels[(y * width + x) * 4] < 128 } }
        return Array(rows.dropFirst().dropLast().map { Array($0.dropFirst().dropLast()) })
    }

    /// Two module rows per line with half blocks, forced black on white so
    /// dark terminal themes still scan.
    public static func terminal(_ modules: [[Bool]], quiet: Int = 2) -> String {
        let size = modules.count + quiet * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quiet, my = y - quiet
            return mx >= 0 && my >= 0 && my < modules.count && mx < modules.count && modules[my][mx]
        }
        var out = ""
        for y in stride(from: 0, to: size, by: 2) {
            for x in 0..<size {
                let top = dark(x, y), bottom = y + 1 < size && dark(x, y + 1)
                out += "\u{1B}[\(top ? 30 : 97);\(bottom ? 40 : 107)m▀"
            }
            out += "\u{1B}[0m\n"
        }
        return out
    }

    /// This Mac's VPN (100.64/10) addresses, e.g. its Tailscale IP.
    public static func vpnAddresses() -> [String] { interfaceAddresses().filter { LocalNetwork.isVPN($0.1) }.map(\.1) }

    /// Private IPv4 addresses of active interfaces, Wi-Fi/Ethernet first.
    public static func lanAddresses() -> [String] {
        interfaceAddresses().filter { LocalNetwork.isPrivateIPv4($0.1) }
            .sorted { ($0.0.hasPrefix("en") ? 0 : 1, $0.0) < ($1.0.hasPrefix("en") ? 0 : 1, $1.0) }.map(\.1)
    }

    private static func interfaceAddresses() -> [(String, String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            result.append((String(cString: entry.ifa_name), ip))
        }
        return result
    }
}

public enum LocalNetwork {
    public static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    /// Carrier-grade NAT space (100.64.0.0/10) that Tailscale and similar VPNs hand out.
    public static func isVPN(_ ip: String) -> Bool {
        var ip = ip.lowercased()
        if ip.hasPrefix("::ffff:") { ip.removeFirst(7) }
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Loopback, RFC 1918, link-local and IPv6 ULA. Everything else is refused
    /// even if a router forwards the port.
    public static func isLocal(_ ip: String) -> Bool {
        var ip = ip.lowercased()
        if ip.hasPrefix("::ffff:") { ip.removeFirst(7) }
        if ip.contains(":") {
            return ip == "::1" || ip.hasPrefix("fe80:") || ip.hasPrefix("fc") || ip.hasPrefix("fd")
        }
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || isPrivateIPv4(ip) || (parts[0] == 169 && parts[1] == 254)
    }
}
