import Foundation

enum NetworkInfo {
    struct Address { let interface: String; let ip: String }

    /// Tailscale hands out addresses from the 100.64.0.0/10 CGNAT range.
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func ipv4Addresses() -> [Address] {
        var out: [Address] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: buf)
            guard !ip.hasPrefix("169.254") else { continue }   // self-assigned
            out.append(Address(interface: String(cString: cur.pointee.ifa_name), ip: ip))
        }
        return out
    }

    static var tailscaleIP: String? {
        ipv4Addresses().first { isTailscale($0.ip) }?.ip
    }

    static var lanIPs: [String] {
        ipv4Addresses().filter { !isTailscale($0.ip) }.map(\.ip)
    }

    static var tailscaleInstalled: Bool {
        let paths = ["/Applications/Tailscale.app", "/usr/local/bin/tailscale",
                     "/opt/homebrew/bin/tailscale"]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// The MagicDNS name, when the CLI is present and logged in.
    static func tailscaleHostname() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                          "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["status", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = json["Self"] as? [String: Any],
              let dns = selfNode["DNSName"] as? String, !dns.isEmpty
        else { return nil }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }
}
