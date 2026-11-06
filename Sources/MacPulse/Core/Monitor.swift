import Foundation
import SwiftUI
import ServiceManagement

/// One element that can be shown next to (or instead of) the menu bar icon. Any combination is allowed.
enum MenuBarItem: String, CaseIterable, Identifiable {
    case power, cpu, memory, netDown, netUp, battery, publicIP, localIP
    var id: String { rawValue }
    var label: String {
        switch self {
        case .power: T("استهلاك الطاقة (واط)", "Power draw (W)")
        case .cpu: T("المعالج %", "CPU %")
        case .memory: T("الذاكرة %", "Memory %")
        case .netDown: T("سرعة التنزيل", "Download speed")
        case .netUp: T("سرعة الرفع", "Upload speed")
        case .battery: T("البطارية %", "Battery %")
        case .publicIP: T("الـ IP العام والدولة", "Public IP & country")
        case .localIP: T("الـ IP المحلي", "Local IP")
        }
    }
    var symbol: String {
        switch self {
        case .power: "bolt.fill"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .netDown: "arrow.down"
        case .netUp: "arrow.up"
        case .battery: "battery.75percent"
        case .publicIP: "globe"
        case .localIP: "network"
        }
    }
}

/// A rendered piece of the menu bar label: optional SF Symbol + text (a flag emoji is text).
struct MenuBarSegment: Equatable {
    var symbol: String?
    var text: String
}

/// Main-thread state the UI observes. While the panel is closed only the menu bar title is touched,
/// so SwiftUI does no work in the background.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var live: [LivePoint] = []
    /// Items shown in the menu bar, in canonical order. Empty + icon = icon only.
    @Published var menuBarItems: [MenuBarItem] {
        didSet {
            UserDefaults.standard.set(menuBarItems.map(\.rawValue), forKey: "menuBarItems")
            if menuBarItems.contains(.publicIP) && !publicIPEnabled { publicIPEnabled = true }
            onMenuBarChange?()
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon"); onMenuBarChange?() }
    }
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            L10n.apply(language)
            onMenuBarChange?()
        }
    }
    /// Opt-in: contacts ipinfo.io (fallback api.country.is) only while enabled.
    @Published var publicIPEnabled: Bool {
        didSet {
            UserDefaults.standard.set(publicIPEnabled, forKey: "publicIPEnabled")
            if publicIPEnabled { publicIPService.start() } else {
                publicIPService.stop(); publicIP = nil
                if menuBarItems.contains(.publicIP) { menuBarItems.removeAll { $0 == .publicIP } }
            }
        }
    }
    @Published private(set) var publicIP: PublicIPService.Info?
    @Published private(set) var localIP: (ip: String, interface: String)?
    @Published var backgroundInterval: Double {
        didSet { UserDefaults.standard.set(backgroundInterval, forKey: "bgInterval"); applyInterval() }
    }
    @Published var resolveHostnames: Bool {
        didSet { UserDefaults.standard.set(resolveHostnames, forKey: "resolveHostnames"); sampler.setResolveHostnames(resolveHostnames) }
    }
    @Published private(set) var launchAtLogin = false
    @Published var launchAtLoginError: String?

    let sampler = Sampler()
    let publicIPService = PublicIPService()
    var onMenuBarChange: (() -> Void)?
    private(set) var latest = Snapshot()
    private var liveBuffer: [LivePoint] = []
    private(set) var isPanelVisible = false

    private init() {
        let d = UserDefaults.standard
        let lang = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        language = lang
        L10n.apply(lang)
        if let raw = d.array(forKey: "menuBarItems") as? [String] {
            let set = Set(raw)
            menuBarItems = MenuBarItem.allCases.filter { set.contains($0.rawValue) }
        } else if let legacy = d.string(forKey: "menuBarMode") {   // migrate the single-choice setting
            let map: [String: MenuBarItem] = ["power": .power, "cpu": .cpu, "memory": .memory, "network": .netDown, "battery": .battery]
            menuBarItems = map[legacy].map { [$0] } ?? []
        } else {
            menuBarItems = [.power]
        }
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        publicIPEnabled = d.bool(forKey: "publicIPEnabled")
        let bg = UserDefaults.standard.double(forKey: "bgInterval")
        backgroundInterval = bg > 0 ? bg : 10
        resolveHostnames = UserDefaults.standard.object(forKey: "resolveHostnames") as? Bool ?? true
        refreshLaunchAtLogin()
    }

    func start() {
        sampler.onSnapshot = { [weak self] snap in
            DispatchQueue.main.async { self?.receive(snap) }
        }
        sampler.setResolveHostnames(resolveHostnames)
        sampler.start(interval: backgroundInterval)
        publicIPService.onUpdate = { [weak self] info in
            self?.publicIP = info
            self?.onMenuBarChange?()
        }
        if publicIPEnabled { publicIPService.start() }
        if !UserDefaults.standard.bool(forKey: "didOfferLogin") {
            UserDefaults.standard.set(true, forKey: "didOfferLogin")
            setLaunchAtLogin(true)   // default ON for a monitor; user can turn it off in Settings
        }
    }

    private func receive(_ s: Snapshot) {
        latest = s
        liveBuffer.append(LivePoint(t: s.date, cpu: s.cpu.usage, mem: s.memory.usedFraction,
                                    power: s.battery.systemPowerW ?? s.appsPowerW, netIn: s.netInRate, netOut: s.netOutRate))
        let cutoff = Date().addingTimeInterval(-15 * 60)
        if let idx = liveBuffer.firstIndex(where: { $0.t >= cutoff }), idx > 0 { liveBuffer.removeFirst(idx) }
        if isPanelVisible || menuBarItems.contains(.localIP) {
            let l = LocalAddress.primary()
            if l?.ip != localIP?.ip { localIP = l }
        }
        if isPanelVisible { publish() }
        onMenuBarChange?()
        if Self.dumpEnabled { Self.dump(s) }
    }

    private static let dumpEnabled = ProcessInfo.processInfo.environment["MACPULSE_DUMP"] != nil

    /// Diagnostics: `MACPULSE_DUMP=1 MacPulse.app/Contents/MacOS/MacPulse`
    private static func dump(_ s: Snapshot) {
        var out = "\n=== \(s.date) ===\n"
        out += String(format: "CPU %.1f%%  MEM %@/%@ pressure=%@  swap %@\n", s.cpu.usage * 100, Fmt.bytes(s.memory.used), Fmt.bytes(s.memory.total), s.memory.pressure.label, Fmt.bytes(s.memory.swapUsed))
        let b = s.battery
        out += String(format: "BATT %.0f%% charging=%d ac=%d sysW=%@ battW=%.2f health=%.1f%% cycles=%d\n", b.percent * 100, b.isCharging ? 1 : 0, b.externalConnected ? 1 : 0, b.systemPowerW.map { String(format: "%.2f", $0) } ?? "nil", b.batteryPowerW, b.health * 100, b.cycleCount)
        out += "NET in=\(Fmt.rate(s.netInRate)) out=\(Fmt.rate(s.netOutRate)) attributed=\(Fmt.rate(s.attributedNetRate)) unreadable=\(s.unreadableProcesses) appsW=\(Fmt.watts(s.appsPowerW))\n"
        for a in s.apps.prefix(6) { out += "  E \(a.name): \(Fmt.watts(a.powerW)) cpu=\(String(format: "%.1f", a.cpuPercent))% mem=\(Fmt.bytes(a.memoryBytes)) procs=\(a.processes.count)\n" }
        for a in s.apps.sorted(by: { $0.memoryBytes > $1.memoryBytes }).prefix(4) { out += "  M \(a.name): \(Fmt.bytes(a.memoryBytes))\n" }
        for a in s.apps.sorted(by: { $0.netTotalRate > $1.netTotalRate }).prefix(4) where a.netTotalRate > 0 { out += "  N \(a.name): \(Fmt.rate(a.netTotalRate))\n" }
        for d in s.destinations.prefix(4) { out += "  D \(d.appName) → \(d.host ?? d.address) \(d.proto) \(Fmt.rate(d.total))\n" }
        out += "  SELF cpu=\(String(format: "%.2f", s.selfUsage.cpuPercent))% mem=\(Fmt.bytes(s.selfUsage.memoryBytes))\n"
        FileHandle.standardOutput.write(out.data(using: .utf8)!)
    }

    private func publish() {
        snapshot = latest
        live = Self.downsample(liveBuffer, to: 90)
    }

    /// Charts cost grows with mark count; 15 min at 2 s would be 450 points × several marks per chart.
    /// Bucket-average down to `n` points (peaks in network rate are kept via max).
    nonisolated static func downsample(_ pts: [LivePoint], to n: Int) -> [LivePoint] {
        guard pts.count > n, n > 0 else { return pts }
        let step = Double(pts.count) / Double(n)
        return (0..<n).map { i in
            let lo = Int(Double(i) * step), hi = min(pts.count, max(lo + 1, Int(Double(i + 1) * step)))
            let s = pts[lo..<hi]
            let c = Double(s.count)
            return LivePoint(t: s.last!.t,
                             cpu: s.reduce(0) { $0 + $1.cpu } / c,
                             mem: s.reduce(0) { $0 + $1.mem } / c,
                             power: s.reduce(0) { $0 + $1.power } / c,
                             netIn: s.map(\.netIn).max() ?? 0,
                             netOut: s.map(\.netOut).max() ?? 0)
        }
    }

    func panelDidOpen() {
        isPanelVisible = true
        publish()
        applyInterval()
        sampler.sampleNow()
    }

    func panelDidClose() {
        isPanelVisible = false
        applyInterval()
    }

    private func applyInterval() {
        sampler.setInterval(isPanelVisible ? 2 : backgroundInterval)
    }

    // MARK: - Launch at login (SMAppService, macOS 13+)

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError = T("يحتاج موافقة من إعدادات النظام ← عام ← عناصر تسجيل الدخول",
                                   "Needs approval in System Settings → General → Login Items")
        }
    }

    // MARK: - Menu bar label

    func menuBarSegments(_ items: [MenuBarItem]? = nil) -> [MenuBarSegment] {
        let s = latest
        var out: [MenuBarSegment] = []
        for item in items ?? menuBarItems {
            switch item {
            case .power:
                let w = s.battery.systemPowerW ?? s.appsPowerW
                if w > 0 { out.append(.init(symbol: item.symbol, text: Fmt.watts(w, compact: true))) }
            case .cpu: out.append(.init(symbol: item.symbol, text: Fmt.percent(s.cpu.usage)))
            case .memory: out.append(.init(symbol: item.symbol, text: Fmt.percent(s.memory.usedFraction)))
            case .netDown: out.append(.init(symbol: item.symbol, text: Fmt.rate(s.netInRate, compact: true)))
            case .netUp: out.append(.init(symbol: item.symbol, text: Fmt.rate(s.netOutRate, compact: true)))
            case .battery:
                if s.battery.present {
                    let sym = s.battery.isCharging ? "battery.100percent.bolt" : Self.batterySymbol(s.battery.percent)
                    out.append(.init(symbol: sym, text: Fmt.percent(s.battery.percent)))
                }
            case .publicIP:
                if let p = publicIP {
                    if let cc = p.countryCode { out.append(.init(symbol: nil, text: flagEmoji(cc) + " " + p.ip)) }
                    else { out.append(.init(symbol: item.symbol, text: p.ip)) }
                } else {
                    out.append(.init(symbol: item.symbol, text: "…"))
                }
            case .localIP:
                if let l = localIP { out.append(.init(symbol: item.symbol, text: l.ip)) }
            }
        }
        return out
    }

    static func batterySymbol(_ f: Double) -> String {
        switch f { case ..<0.13: "battery.0percent"; case ..<0.38: "battery.25percent"; case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"; default: "battery.100percent" }
    }

    var menuBarSymbol: String {
        let s = latest
        if s.memory.pressure == .critical { return "exclamationmark.triangle.fill" }
        if s.battery.present {
            if s.battery.isCharging { return "bolt.fill" }
            if s.battery.externalConnected { return "powerplug.fill" }
        }
        return "waveform.path.ecg"
    }
}

// MARK: - Formatting (Latin digits, compact units)

extension UInt64 {
    /// Saturating, NaN-safe conversion (a plain `UInt64(Double)` traps on NaN, ∞ or negatives).
    init(clamping d: Double) {
        if !d.isFinite || d <= 0 { self = 0 } else if d >= 1.8e19 { self = .max } else { self = UInt64(d) }
    }
}

extension Int {
    init(clamping d: Double) {
        if !d.isFinite { self = 0 } else if d >= 9.2e18 { self = .max } else if d <= -9.2e18 { self = .min } else { self = Int(d) }
    }
}

enum Fmt {
    /// Wraps a left-to-right run (number + unit, "↓x ↑y") in Unicode isolates (LRI…PDI) when the UI is
    /// Arabic, so the bidi algorithm can't reorder "3.29 GB" into "GB 3.29" inside RTL sentences.
    static func iso(_ s: String) -> String { L10n.isArabic ? "\u{2066}" + s + "\u{2069}" : s }

    /// "↓1.2 MB ↑30 KB" as one isolated LTR run.
    static func updown(_ down: String, _ up: String) -> String { iso("↓" + down + " ↑" + up) }

    private static let bytesFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .binary; f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func bytes(_ b: Double) -> String { bytes(UInt64(clamping: b)) }
    static func bytes(_ b: UInt64) -> String { iso(rawBytes(b)) }
    private static func rawBytes(_ b: UInt64) -> String {
        let v = Double(b)
        if v < 1024 { return "\(b) B" }
        if v < 1024 * 1024 { return String(format: "%.0f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: v < 10 * 1024 * 1024 ? "%.1f MB" : "%.0f MB", v / 1048576) }
        return String(format: "%.2f GB", v / 1073741824)
    }

    static func rate(_ bps: Double, compact: Bool = false) -> String {
        let v = max(0, bps)
        let s: String
        if v < 1024 { s = String(format: "%.0f B", v) }
        else if v < 1048576 { s = String(format: "%.0f KB", v / 1024) }
        else if v < 1073741824 { s = String(format: v < 10485760 ? "%.1f MB" : "%.0f MB", v / 1048576) }
        else { s = String(format: "%.2f GB", v / 1073741824) }
        return iso(compact ? s : s + "/s")
    }

    static func percent(_ f: Double, digits: Int = 0) -> String { iso(String(format: "%.\(digits)f%%", f * 100)) }

    static func watts(_ w: Double, compact: Bool = false) -> String { iso(rawWatts(w, compact: compact)) }
    private static func rawWatts(_ w: Double, compact: Bool) -> String {
        if w < 0.01 { return compact ? "0W" : "0 W" }
        if w < 10 { return String(format: compact ? "%.1fW" : "%.2f W", w) }
        return String(format: compact ? "%.0fW" : "%.1f W", w)
    }

    static func energy(_ j: Double) -> String { iso(rawEnergy(j)) }
    private static func rawEnergy(_ j: Double) -> String {
        let wh = j / 3600
        if wh < 1 { return String(format: "%.0f mWh", wh * 1000) }
        return String(format: "%.2f Wh", wh)
    }

    static func duration(minutes m: Int) -> String {
        let h = m / 60, mm = m % 60
        return h > 0 ? T("\(h) س \(mm) د", "\(h)h \(mm)m") : T("\(mm) د", "\(mm)m")
    }

    static func seconds(_ s: Double) -> String {
        if s < 60 { return String(format: T("%.0f ث", "%.0fs"), s) }
        if s < 3600 { return String(format: T("%.0f د", "%.0fm"), s / 60) }
        return String(format: T("%.1f س", "%.1fh"), s / 3600)
    }
}
