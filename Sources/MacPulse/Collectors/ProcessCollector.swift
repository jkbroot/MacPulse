import Foundation
import Darwin

/// Per-process CPU, energy, wakeups and memory via `proc_pid_rusage(RUSAGE_INFO_V6)`.
/// One syscall per process, no subprocesses, no root. Rates use the real elapsed time.
final class ProcessCollector {
    struct Sample {
        let pid: pid_t
        let name: String
        let owner: AppResolver.Owner
        let cpuNs: UInt64        // delta
        let energyNj: UInt64     // delta
        let wakeups: UInt64      // delta
        let footprint: UInt64
    }

    private struct Prev { let start: UInt64; let cpu: UInt64; let energy: UInt64; let wakeups: UInt64 }

    let resolver = AppResolver()
    private var prev: [pid_t: Prev] = [:]
    private var pids = [pid_t](repeating: 0, count: 2048)
    private let numer: UInt64
    private let denom: UInt64
    private(set) var unreadable = 0
    /// Pids that refused rusage (other users / protected). Retrying ~300 of them each tick was a third of
    /// the scan cost; we skip them and re-probe every 60 s (also handles pid reuse).
    private var denied = Set<pid_t>()
    private var deniedReset = Date()

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer); denom = UInt64(tb.denom)
    }

    private func ns(_ ticks: UInt64) -> UInt64 { ticks &* numer / denom }

    func sample() -> [Sample] {
        var count = Int(proc_listallpids(nil, 0))
        if count + 64 > pids.count { pids = [pid_t](repeating: 0, count: count + 256) }
        count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }

        var out: [Sample] = []
        out.reserveCapacity(count)
        var alive = Set<pid_t>(minimumCapacity: count)
        var failed = 0
        if Date().timeIntervalSince(deniedReset) > 60 { denied.removeAll(keepingCapacity: true); deniedReset = Date() }

        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            if denied.contains(pid) { failed += 1; continue }
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else { failed += 1; if errno == EPERM { denied.insert(pid) }; continue }
            alive.insert(pid)

            let start = info.ri_proc_start_abstime
            let cpu = ns(info.ri_user_time &+ info.ri_system_time)
            let energy = info.ri_energy_nj
            let wake = info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups

            defer { prev[pid] = Prev(start: start, cpu: cpu, energy: energy, wakeups: wake) }
            guard let p = prev[pid], p.start == start else { continue } // first sight: baseline only

            let resolved = resolver.resolve(pid: pid, start: start)
            out.append(Sample(
                pid: pid, name: resolved.name, owner: resolved.owner,
                cpuNs: cpu >= p.cpu ? cpu - p.cpu : 0,
                energyNj: energy >= p.energy ? energy - p.energy : 0,
                wakeups: wake >= p.wakeups ? wake - p.wakeups : 0,
                footprint: info.ri_phys_footprint))
        }

        unreadable = failed
        if prev.count > alive.count + 64 {
            prev = prev.filter { alive.contains($0.key) }
            resolver.prune(alive: alive)
        }
        return out
    }

    /// Owner lookup for pids we only learn about from nettop (e.g. root daemons we cannot rusage).
    func owner(for pid: pid_t) -> (AppResolver.Owner, String) {
        let start = prev[pid]?.start ?? 0
        let r = resolver.resolve(pid: pid, start: start)
        return (r.owner, r.name)
    }
}
