import Foundation
import Network
import Darwin
import SystemConfiguration

/// Local address of the primary interface (no network traffic: SCDynamicStore + getifaddrs).
enum LocalAddress {
    static func primary() -> (ip: String, interface: String)? {
        var primaryIF: String?
        if let store = SCDynamicStoreCreate(nil, "MacPulse" as CFString, nil, nil),
           let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primaryIF = v4["PrimaryInterface"] as? String
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var fallback: (String, String)?
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            if name == primaryIF { return (ip, name) }
            if fallback == nil, name.hasPrefix("en") { fallback = (ip, name) }
        }
        return fallback
    }
}

/// Public IP and country. **Opt-in**: runs only while the user shows it (menu bar or Network tab).
///
/// Privacy/security design:
/// - One HTTPS GET, ephemeral session (no cookies, cache or credentials), nothing about the user is sent.
/// - Refreshes only when the network path changes (Wi-Fi switch, VPN on/off) and every 30 min,
///   never on the sampling timer.
/// - Response is size-limited, strictly decoded, the IP is validated with inet_pton and the country
///   must be two letters A–Z, so a hostile/compromised endpoint can't inject arbitrary text into the UI.
final class PublicIPService {
    struct Info: Equatable {
        let ip: String
        let countryCode: String?
        let org: String?
        let fetched: Date
    }

    var onUpdate: ((Info?) -> Void)?
    private(set) var current: Info?
    private var pathMonitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "macpulse.publicip", qos: .utility)
    private var pending: DispatchWorkItem?
    private var running = false
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                if path.status == .satisfied { self.scheduleFetch(after: 2) }   // debounce flapping
                else { self.publish(nil) }
            }
            m.start(queue: queue)
            pathMonitor = m
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1800, repeating: 1800, leeway: .seconds(120))
            t.setEventHandler { [weak self] in self?.scheduleFetch(after: 0) }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            pathMonitor?.cancel(); pathMonitor = nil
            timer?.cancel(); timer = nil
            pending?.cancel(); pending = nil
        }
    }

    func refreshNow() { queue.async { [self] in if running { scheduleFetch(after: 0) } } }

    private func scheduleFetch(after s: Double) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.fetch(endpoint: 0) }
        pending = w
        queue.asyncAfter(deadline: .now() + s, execute: w)
    }

    private static let endpoints = [
        URL(string: "https://ipinfo.io/json")!,
        URL(string: "https://api.country.is/")!,
    ]

    private func fetch(endpoint i: Int) {
        guard running, i < Self.endpoints.count else { return }
        var req = URLRequest(url: Self.endpoints[i])
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            self.queue.async {
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200, let info = Self.parse(data) {
                    self.publish(info)
                } else {
                    self.fetch(endpoint: i + 1)
                }
            }
        }.resume()
    }

    private func publish(_ info: Info?) {
        guard info != current else { return }
        current = info
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(info) }
    }

    static func parse(_ data: Data) -> Info? {
        guard data.count < 8192,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = obj["ip"] as? String, isValidIP(ip) else { return nil }
        var cc = obj["country"] as? String
        if let c = cc, c.count != 2 || !c.allSatisfy({ $0.isASCII && $0.isUppercase && $0.isLetter }) { cc = nil }
        var org = obj["org"] as? String
        if let o = org { org = String(o.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(60).map(Character.init)) }
        return Info(ip: ip, countryCode: cc, org: org, fetched: Date())
    }

    static func isValidIP(_ s: String) -> Bool {
        guard s.count <= 45 else { return false }
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
    }
}
