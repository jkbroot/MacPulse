import Foundation
import Darwin

/// The monitoring engine. Runs on one utility-QoS serial queue with a coalescing-friendly timer.
/// - Fast cadence (≈2 s) only while the panel is open; slow cadence (default 10 s) otherwise.
/// - Rates are always computed from the real elapsed time, so timer coalescing / App Nap /
///   sleep can never inflate or deflate a number.
/// - History is aggregated in memory and written to SQLite once per minute.
final class Sampler {
    private let queue = DispatchQueue(label: "macpulse.sampler", qos: .utility)
    private static let profile = ProcessInfo.processInfo.environment["MACPULSE_PROFILE"] != nil
    private var timer: DispatchSourceTimer?

    private let processes = ProcessCollector()
    private let system = SystemCollector()
    private let battery = BatteryCollector()
    private let interfaces = InterfaceCollector()
    private let nettop = NettopCollector()
    let dns = HostResolver()
    let store = HistoryStore()

    private var lastTick: TimeInterval = 0
    private var interval: Double = 10
    private var useEnergyCounters = true
    private var resolveHostnames = true
    private let myPid = getpid()

    var onSnapshot: ((Snapshot) -> Void)?

    // History accumulators (queue-confined)
    private var minuteStart = 0
    private var mCount = 0, mBattSum = 0.0, mBattN = 0, mWSum = 0.0, mWN = 0, mCPU = 0.0, mMem = 0.0
    private var mIn = 0.0, mOut = 0.0, mAC = true, mCharging = false
    private var pendingSystem: [HistoryStore.SystemRow] = []
    private var appAcc: [String: HistoryStore.AppRow] = [:]
    private var destAcc: [String: HistoryStore.DestRow] = [:]
    private var lastFlush = Date()
    private var lastPrune = Date.distantPast

    // MARK: - Lifecycle

    func start(interval: Double) {
        queue.async { [self] in
            self.interval = interval
            _ = system.cpu()                         // prime CPU tick baseline
            _ = processes.sample()                   // prime per-process baseline
            _ = interfaces.sample(elapsed: 0)
            lastTick = ProcessInfo.processInfo.systemUptime
            nettop.start(interval: Int(max(2, interval.rounded())))
            schedule(after: 1.0)
        }
        battery.observeChanges { [weak self] in self?.sampleNow() }
    }

    /// After sleep: restart the measurement window so the first sample isn't averaged over the nap.
    func resetClock() {
        queue.async { [self] in
            _ = system.cpu(); _ = processes.sample(); _ = interfaces.sample(elapsed: 0); _ = nettop.drain()
            lastTick = ProcessInfo.processInfo.systemUptime
        }
    }

    func setInterval(_ s: Double) {
        queue.async { [self] in
            guard abs(s - interval) > 0.01 else { return }
            interval = s
            nettop.setInterval(Int(max(2, s.rounded())))
            schedule(after: min(s, 0.3))
        }
    }

    /// Reverse DNS sends each remote IP to the configured DNS resolver; users may turn it off.
    func setResolveHostnames(_ on: Bool) { queue.async { [self] in resolveHostnames = on } }

    func sampleNow() { queue.async { [self] in tick() } }

    func shutdown() {
        nettop.stop()
        queue.sync { flushHistory(force: true) }
    }

    private func schedule(after first: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 10–20 % leeway lets macOS coalesce our wakeups with others (big win for idle power).
        t.schedule(deadline: .now() + first, repeating: interval, leeway: .milliseconds(Int(interval * 1000 * (interval > 3 ? 0.2 : 0.1))))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - Tick

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        guard elapsed > 0.25 else { return }
        lastTick = now

        let prof = Self.profile
        var marks: [(String, UInt64)] = prof ? [("start", clock_gettime_nsec_np(CLOCK_UPTIME_RAW))] : []
        func mark(_ n: String) { if prof { marks.append((n, clock_gettime_nsec_np(CLOCK_UPTIME_RAW))) } }
        defer {
            if prof, marks.count > 1 {
                var line = "TICK"
                for i in 1..<marks.count { line += String(format: " %@=%.2fms", marks[i].0, Double(marks[i].1 - marks[i - 1].1) / 1e6) }
                line += String(format: " total=%.2fms\n", Double(marks.last!.1 - marks[0].1) / 1e6)
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }

        var snap = Snapshot()
        snap.cpu = system.cpu()
        snap.memory = system.memory()
        snap.battery = battery.read()
        mark("sys+batt")

        // Network: interface ground truth
        let ifs = interfaces.sample(elapsed: elapsed)
        snap.interfaces = ifs
        for i in ifs where InterfaceCollector.isPhysical(i.bsdName) {
            snap.netInRate += i.inRate
            snap.netOutRate += i.outRate
        }

        mark("ifaces")
        // Processes → apps
        let procs = processes.sample()
        mark("procs")
        snap.unreadableProcesses = processes.unreadable
        var (netPid, netDest) = nettop.drain()
        // Sanity cap: per-app bytes can never exceed what the physical interfaces actually moved.
        // (nettop samples on its own clock, so allow some slack before scaling.)
        let ifIn = snap.netInRate * elapsed, ifOut = snap.netOutRate * elapsed
        let sumIn = Double(netPid.values.reduce(UInt64(0)) { $0 + $1.inB })
        let sumOut = Double(netPid.values.reduce(UInt64(0)) { $0 + $1.outB })
        let kIn = sumIn > ifIn * 1.5 + 262_144 ? (ifIn * 1.5 + 262_144) / sumIn : 1
        let kOut = sumOut > ifOut * 1.5 + 262_144 ? (ifOut * 1.5 + 262_144) / sumOut : 1
        if kIn < 1 || kOut < 1 {
            for (k, v) in netPid { netPid[k] = .init(inB: UInt64(clamping: Double(v.inB) * kIn), outB: UInt64(clamping: Double(v.outB) * kOut)) }
            for (k, v) in netDest { netDest[k] = .init(inB: UInt64(clamping: Double(v.inB) * kIn), outB: UInt64(clamping: Double(v.outB) * kOut)) }
        }

        let totalEnergy = procs.reduce(UInt64(0)) { $0 + $1.energyNj }
        let totalCPU = procs.reduce(UInt64(0)) { $0 + $1.cpuNs }
        if totalEnergy == 0 && totalCPU > 0 { useEnergyCounters = false }
        let sysW = snap.battery.systemPowerW ?? 0

        var apps: [String: AppUsage] = [:]
        var pidOwner: [pid_t: String] = [:]
        for p in procs {
            let cpuPct = Double(p.cpuNs) / 1e9 / elapsed * 100
            let watts: Double = useEnergyCounters
                ? Double(p.energyNj) / 1e9 / elapsed
                : (totalCPU > 0 ? sysW * 0.6 * Double(p.cpuNs) / Double(totalCPU) : 0)
            let net = netPid[p.pid]
            let pu = ProcessUsage(pid: p.pid, name: p.name, cpuPercent: cpuPct, powerW: watts,
                                  memoryBytes: p.footprint, wakeupsPerSec: Double(p.wakeups) / elapsed,
                                  netInRate: Double(net?.inB ?? 0) / elapsed, netOutRate: Double(net?.outB ?? 0) / elapsed)
            pidOwner[p.pid] = p.owner.id
            var a = apps[p.owner.id] ?? AppUsage(id: p.owner.id, name: p.owner.name, bundlePath: p.owner.bundlePath, isSystem: p.owner.isSystem)
            a.cpuPercent += pu.cpuPercent
            a.powerW += pu.powerW
            a.memoryBytes += pu.memoryBytes
            a.wakeupsPerSec += pu.wakeupsPerSec
            a.netInRate += pu.netInRate
            a.netOutRate += pu.netOutRate
            a.processes.append(pu)
            apps[p.owner.id] = a
            if p.pid == myPid { snap.selfUsage = SelfUsage(cpuPercent: cpuPct, memoryBytes: p.footprint) }
        }

        // Network-only pids (root daemons we cannot rusage, or processes we saw for the first time)
        for (pid, b) in netPid where pidOwner[pid] == nil {
            let (owner, name) = processes.owner(for: pid)
            pidOwner[pid] = owner.id
            var a = apps[owner.id] ?? AppUsage(id: owner.id, name: owner.name, bundlePath: owner.bundlePath, isSystem: owner.isSystem)
            let inR = Double(b.inB) / elapsed, outR = Double(b.outB) / elapsed
            a.netInRate += inR
            a.netOutRate += outR
            a.processes.append(ProcessUsage(pid: pid, name: name, cpuPercent: 0, powerW: 0, memoryBytes: 0,
                                            wakeupsPerSec: 0, netInRate: inR, netOutRate: outR))
            apps[owner.id] = a
        }

        // Destinations
        var dests: [String: DestinationUsage] = [:]
        for (k, b) in netDest {
            guard let appID = pidOwner[k.pid], let app = apps[appID] else { continue }
            let key = appID + "|" + k.host
            var d = dests[key] ?? DestinationUsage(appID: appID, appName: app.name, address: k.host, host: nil, proto: k.proto, inRate: 0, outRate: 0)
            d.inRate += Double(b.inB) / elapsed
            d.outRate += Double(b.outB) / elapsed
            dests[key] = d
        }
        var destList = dests.values.sorted { $0.total > $1.total }
        if resolveHostnames { dns.request(destList.prefix(40).map(\.address)) }
        for i in destList.indices { destList[i].host = dns.cached(destList[i].address) }
        snap.destinations = destList
        mark("aggregate")

        var appList = Array(apps.values)
        for i in appList.indices { appList[i].processes.sort { $0.powerW + $0.cpuPercent / 100 > $1.powerW + $1.cpuPercent / 100 } }
        appList.sort { $0.powerW > $1.powerW }
        snap.apps = appList
        snap.appsPowerW = appList.reduce(0) { $0 + $1.powerW }
        snap.attributedNetRate = appList.reduce(0) { $0 + $1.netTotalRate }

        accumulate(snap, elapsed: elapsed, dests: destList)
        mark("history")
        onSnapshot?(snap)
    }

    // MARK: - History

    private func accumulate(_ s: Snapshot, elapsed: Double, dests: [DestinationUsage]) {
        let nowTs = Int(Date().timeIntervalSince1970)
        let minute = nowTs / 60 * 60
        if minuteStart == 0 { minuteStart = minute }
        if minute != minuteStart { closeMinute(); minuteStart = minute }

        mCount += 1
        if s.battery.present { mBattSum += s.battery.percent * 100; mBattN += 1 }
        if let w = s.battery.systemPowerW { mWSum += w; mWN += 1 }
        mCPU += s.cpu.usage * 100
        mMem += s.memory.usedFraction * 100
        mIn += s.netInRate * elapsed
        mOut += s.netOutRate * elapsed
        mAC = !s.battery.present || s.battery.externalConnected
        mCharging = s.battery.isCharging

        let hour = nowTs / 3600 * 3600
        let onBattery = s.battery.present && !s.battery.externalConnected
        for a in s.apps {
            let e = a.powerW * elapsed
            let cpuS = a.cpuPercent / 100 * elapsed
            let ni = a.netInRate * elapsed, no = a.netOutRate * elapsed
            guard e > 0.0001 || cpuS > 0.001 || ni + no > 0 || a.memoryBytes > 50_000_000 else { continue }
            var r = appAcc[a.id] ?? HistoryStore.AppRow(hour: hour, app: a.id, name: a.name, energyJ: 0, cpuS: 0, netIn: 0, netOut: 0, memPeak: 0, batteryEnergyJ: 0)
            if r.hour != hour { flushHistory(force: true); r = HistoryStore.AppRow(hour: hour, app: a.id, name: a.name, energyJ: 0, cpuS: 0, netIn: 0, netOut: 0, memPeak: 0, batteryEnergyJ: 0) }
            r.energyJ += e; r.cpuS += cpuS; r.netIn += ni; r.netOut += no
            r.memPeak = max(r.memPeak, Double(a.memoryBytes))
            if onBattery { r.batteryEnergyJ += e }
            appAcc[a.id] = r
        }
        for d in dests {
            let key = d.appID + "|" + d.address
            var r = destAcc[key] ?? HistoryStore.DestRow(hour: hour, app: d.appID, host: d.address, label: d.host ?? d.address, bytesIn: 0, bytesOut: 0)
            r.bytesIn += d.inRate * elapsed
            r.bytesOut += d.outRate * elapsed
            if let h = d.host { r.label = h }
            destAcc[key] = r
        }

        if Date().timeIntervalSince(lastFlush) >= 60 { flushHistory(force: false) }
    }

    private func closeMinute() {
        guard mCount > 0 else { return }
        pendingSystem.append(HistoryStore.SystemRow(
            ts: minuteStart, battery: mBattN > 0 ? mBattSum / Double(mBattN) : nil, charging: mCharging, onAC: mAC,
            sysW: mWN > 0 ? mWSum / Double(mWN) : nil, cpu: mCPU / Double(mCount), mem: mMem / Double(mCount),
            netIn: mIn, netOut: mOut))
        mCount = 0; mBattSum = 0; mBattN = 0; mWSum = 0; mWN = 0; mCPU = 0; mMem = 0; mIn = 0; mOut = 0
    }

    private func flushHistory(force: Bool) {
        if force { closeMinute() }
        store.write(system: pendingSystem, apps: Array(appAcc.values), dests: Array(destAcc.values))
        pendingSystem.removeAll(); appAcc.removeAll(); destAcc.removeAll()
        lastFlush = Date()
        if Date().timeIntervalSince(lastPrune) > 6 * 3600 { store.prune(); lastPrune = Date() }
    }

    /// Run a read on the sampler queue (keeps SQLite single-threaded) and hop back to main.
    func query<T>(_ work: @escaping (HistoryStore) -> T, completion: @escaping (T) -> Void) {
        queue.async { [self] in
            flushHistory(force: false)
            let r = work(store)
            DispatchQueue.main.async { completion(r) }
        }
    }
}
