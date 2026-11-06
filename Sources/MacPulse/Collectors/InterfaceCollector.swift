import Foundation
import Darwin
import SystemConfiguration

/// Interface byte counters via `sysctl(NET_RT_IFLIST2)` — 64-bit counters, so no 4 GB wraparound
/// (unlike `getifaddrs`). This is the ground truth for total throughput.
final class InterfaceCollector {
    struct Counters { var ibytes: UInt64; var obytes: UInt64 }

    private var prev: [String: Counters] = [:]
    private var displayNames: [String: String] = [:]
    private var namesRefreshed = Date.distantPast
    private var buffer = [UInt8]()
    private var indexNames: [UInt16: String] = [:]   // if_indextoname() is a syscall; cache it

    func refreshNamesIfNeeded() {
        guard Date().timeIntervalSince(namesRefreshed) > 300 else { return }
        namesRefreshed = Date()
        var names: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                if let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
                   let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                    names[bsd] = n
                }
            }
        }
        displayNames = names
        indexNames.removeAll()
    }

    private func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        if buffer.count < len { buffer = [UInt8](repeating: 0, count: len + 1024) }
        guard sysctl(&mib, 6, &buffer, &len, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var off = 0
            var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    let flags = Int32(m.ifm_flags)
                    if flags & IFF_LOOPBACK == 0 {
                        var name = indexNames[m.ifm_index]
                        if name == nil, if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                            name = String(cString: nameBuf); indexNames[m.ifm_index] = name
                        }
                        if let name {
                            result[name] = Counters(ibytes: m.ifm_data.ifi_ibytes, obytes: m.ifm_data.ifi_obytes)
                        }
                    }
                }
                off += msgLen
            }
        }
        return result
    }

    /// Physical uplinks count toward the headline total; tunnels (utun) would double count.
    static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge")
    }

    func sample(elapsed: Double) -> [InterfaceUsage] {
        refreshNamesIfNeeded()
        let now = readCounters()
        defer { prev = now }
        guard elapsed > 0 else { return [] }
        var out: [InterfaceUsage] = []
        for (name, c) in now {
            guard let p = prev[name] else { continue }
            let di = c.ibytes >= p.ibytes ? c.ibytes - p.ibytes : 0
            let dout = c.obytes >= p.obytes ? c.obytes - p.obytes : 0
            if c.ibytes == 0 && c.obytes == 0 { continue }
            out.append(InterfaceUsage(
                bsdName: name,
                displayName: displayNames[name] ?? Self.fallbackName(name),
                inRate: Double(di) / elapsed, outRate: Double(dout) / elapsed,
                totalIn: c.ibytes, totalOut: c.obytes))
        }
        return out.sorted { ($0.inRate + $0.outRate, $0.totalIn) > ($1.inRate + $1.outRate, $1.totalIn) }
    }

    private static func fallbackName(_ n: String) -> String {
        if n.hasPrefix("utun") || n.hasPrefix("ipsec") { return T("VPN / نفق", "VPN / tunnel") + " (\(n))" }
        if n.hasPrefix("awdl") || n.hasPrefix("llw") { return "AirDrop/AWDL (\(n))" }
        if n.hasPrefix("bridge") { return T("جسر", "Bridge") + " (\(n))" }
        if n.hasPrefix("anpi") || n.hasPrefix("ap") { return T("داخلي", "Internal") + " (\(n))" }
        return n
    }
}
