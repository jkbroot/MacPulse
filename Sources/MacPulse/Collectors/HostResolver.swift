import Foundation
import Darwin

/// Reverse-DNS for remote addresses, off the sampling path, cached, and with bounded concurrency.
final class HostResolver {
    private let lock = NSLock()
    private var cache: [String: String?] = [:]   // nil value = lookup failed / in flight
    private var inFlight = Set<String>()
    private let queue = DispatchQueue(label: "macpulse.dns", qos: .background, attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 3)

    func cached(_ ip: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[ip] ?? nil
    }

    func request(_ ips: [String]) {
        for ip in ips where ip != "*" && !Self.isPrivate(ip) {
            lock.lock()
            let skip = cache[ip] != nil || inFlight.contains(ip)
            if !skip { inFlight.insert(ip) }
            lock.unlock()
            if skip { continue }
            queue.async { [weak self] in
                guard let self else { return }
                self.limiter.wait(); defer { self.limiter.signal() }
                let name = Self.reverse(ip)
                self.lock.lock()
                self.cache[ip] = .some(name)
                self.inFlight.remove(ip)
                if self.cache.count > 4000 { self.cache.removeAll() }
                self.lock.unlock()
            }
        }
    }

    static func isPrivate(_ ip: String) -> Bool {
        ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("127.") || ip.hasPrefix("fe80")
            || ip.hasPrefix("169.254.") || ip.hasPrefix("::1")
            || (ip.hasPrefix("172.") && (Int(ip.split(separator: ".").dropFirst().first ?? "") ?? 0).isBetween(16, 31))
    }

    private static func reverse(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0
        else { return nil }
        return String(cString: host)
    }
}

private extension Int {
    func isBetween(_ a: Int, _ b: Int) -> Bool { self >= a && self <= b }
}
