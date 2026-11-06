import Foundation
import Darwin

/// Per-process and per-connection network accounting.
///
/// macOS has no public API for per-app bytes; the kernel exposes it through the NetworkStatistics
/// subsystem, which Apple's own `/usr/bin/nettop` reads. We keep exactly ONE long-lived nettop child
/// in CSV logging mode and parse its stream (no process spawned per sample).
/// Counters are cumulative per socket, so deltas are computed here; gaps (e.g. when the interval
/// changes and nettop is restarted) are harmless.
final class NettopCollector {
    struct Bytes { var inB: UInt64 = 0; var outB: UInt64 = 0 }
    struct DestKey: Hashable { let pid: pid_t; let host: String; let proto: String }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "macpulse.nettop", qos: .utility)
    private var childPid: pid_t = 0
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var generation = 0
    private var partial = Data()
    private var wantRunning = false
    private var interval = 5
    private var readBuf = [UInt8](repeating: 0, count: 64 * 1024)

    // Parsing state (guarded by lock).
    private var currentPid: pid_t = -1
    private struct ConnState { var bytes: Bytes; var lastBlock: Int }
    private var lastConn: [String: ConnState] = [:]
    private var seenThisBlock = Set<String>()
    private var blockNumber = 0
    private var primed = false
    private var blockHasRows = false

    // Pending deltas, drained by the sampler.
    private var pendingPid: [pid_t: Bytes] = [:]
    private var pendingDest: [DestKey: Bytes] = [:]

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") }

    func start(interval: Int) {
        lock.lock(); defer { lock.unlock() }
        self.interval = max(1, interval)
        wantRunning = true
        launchLocked()
    }

    func setInterval(_ s: Int) {
        lock.lock(); defer { lock.unlock() }
        let s = max(1, s)
        guard s != interval || childPid == 0 else { return }
        interval = s
        guard wantRunning else { return }
        terminateLocked()
        launchLocked()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        wantRunning = false
        terminateLocked()
    }

    func drain() -> (perPid: [pid_t: Bytes], perDest: [DestKey: Bytes]) {
        lock.lock(); defer { lock.unlock() }
        let r = (pendingPid, pendingDest)
        pendingPid.removeAll(keepingCapacity: true)
        pendingDest.removeAll(keepingCapacity: true)
        return r
    }

    // MARK: - Process management
    //
    // nettop is spawned on a pseudo-terminal, not a pipe, for two measured reasons:
    //  • on a pipe its stdout is block-buffered, so samples arrive late and in bursts;
    //  • with stdin at EOF (/dev/null) it busy-loops at >100% CPU. A pty slave that never
    //    receives input keeps it idle (0.0% CPU) and line-buffered.
    // If MacPulse dies, the pty master closes and nettop exits on its next write.

    private func launchLocked() {
        guard isAvailable, childPid == 0 else { return }
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { close(master) }
            scheduleRestartLocked(); return
        }
        let slavePath = String(cString: name)
        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); scheduleRestartLocked(); return }

        // Raw mode: no "\n" → "\r\n" translation, no echo.
        var tio = termios()
        if tcgetattr(slave, &tio) == 0 { cfmakeraw(&tio); tcsetattr(slave, TCSANOW, &tio) }
        var ws = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &ws)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, slave, 0)
        posix_spawn_file_actions_adddup2(&fa, slave, 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Reset signal dispositions: MacPulse ignores SIGTERM (handled via a dispatch source) and
        // the child must not inherit that, or it could never be stopped.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGTERM, SIGHUP, SIGINT, SIGPIPE] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var noMask = sigset_t(); sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        // Spawn our own binary in guard mode; it starts nettop and guarantees it dies with us.
        guard let selfPath = Bundle.main.executablePath else { close(master); close(slave); return }
        let args = [selfPath, "--nettop-guard", String(getpid()),
                    "-L", "0", "-x", "-n", "-t", "external", "-s", String(interval), "-J", "bytes_in,bytes_out"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [strdup("TERM=dumb"), strdup("PATH=/usr/bin:/bin"), nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, selfPath, &fa, &attr, &argv, &env)
        argv.forEach { free($0) }; env.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        close(slave)
        guard rc == 0 else { close(master); scheduleRestartLocked(); return }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        childPid = pid
        masterFD = master
        generation += 1
        let gen = generation
        partial.removeAll()
        currentPid = -1
        blockHasRows = false
        seenThisBlock.removeAll()

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        rs.setEventHandler { [weak self] in self?.readAvailable(gen: gen) }
        rs.setCancelHandler { close(master) }
        rs.resume()
        readSource = rs

        let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        es.setEventHandler { [weak self] in
            guard let self else { return }
            // Reap only while holding the lock and only if this child is still current; otherwise
            // terminateLocked() owns reaping. Reaping first would free the pid for reuse while
            // `childPid` still names it, and a concurrent terminate could signal an unrelated process.
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.generation == gen else { return }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self.cleanupLocked()
            if self.wantRunning { self.scheduleRestartLocked() }
        }
        es.resume()
        exitSource = es
    }

    private func scheduleRestartLocked() {
        ioQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.wantRunning && self.childPid == 0 { self.launchLocked() }
        }
    }

    private func cleanupLocked() {
        readSource?.cancel(); readSource = nil
        exitSource?.cancel(); exitSource = nil
        masterFD = -1
        childPid = 0
    }

    private func terminateLocked() {
        guard childPid != 0 else { return }
        let pid = childPid
        generation += 1   // ignore the old child's exit event
        cleanupLocked()
        kill(pid, SIGTERM)
        ioQueue.asyncAfter(deadline: .now() + 1) {
            var st: Int32 = 0
            if waitpid(pid, &st, WNOHANG) == 0 { kill(pid, SIGKILL); waitpid(pid, &st, 0) }
        }
    }

    private func readAvailable(gen: Int) {
        lock.lock()
        let fd = masterFD
        let current = generation == gen
        lock.unlock()
        guard current, fd >= 0 else { return }
        while true {
            let n = readBuf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { consume(Data(readBuf[0..<n])) } else { break }
        }
    }

    // MARK: - Parsing

    private func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            if var line = String(data: lineData, encoding: .utf8) { if line.hasSuffix("\r") { line.removeLast() }; parse(line) }
        }
        if partial.count > 1 << 20 { partial.removeAll() } // defensive
    }

    /// Test hook: feed raw nettop lines exactly as the pty reader would.
    func ingestForTesting(_ text: String) { consume(Data(text.utf8)) }

    private func parse(_ line: String) {
        if line.hasPrefix(",") { endBlock(); return }   // header row starts every sample
        // Rows end with "<bytes_in>,<bytes_out>," — parse from the END, because the first field contains
        // a process name, which any local program can choose (it may contain commas or "<->").
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4, fields[fields.count - 1].isEmpty,
              let inB = UInt64(fields[fields.count - 3]), let outB = UInt64(fields[fields.count - 2]),
              inB < Self.maxCounter, outB < Self.maxCounter   // reject absurd values: no overflow later
        else { return }
        let desc = fields[0..<(fields.count - 3)].joined(separator: ",")
        blockHasRows = true

        if Self.isConnectionRow(desc), let arrow = desc.range(of: "<->") {
            // Connection row: "tcp4 192.168.1.5:50000<->17.1.2.3:443"
            guard currentPid >= 0 else { return }
            let head = desc[..<arrow.lowerBound]
            let proto = head.split(separator: " ").first.map(String.init) ?? "?"
            let remote = String(desc[arrow.upperBound...])
            // Unconnected/listening sockets ("udp6 *.5353<->*.*") are skipped: multicast (mDNS) packets are
            // counted once per socket, so a process with 18 such sockets would report 18× the real traffic.
            if remote.hasPrefix("*") { return }
            // Two sockets can print identically (e.g. "udp6 *.5353<->*.*"): make keys unique per block.
            var key = "\(currentPid)|\(desc)"
            var dup = 1
            while seenThisBlock.contains(key) { dup += 1; key = "\(currentPid)|\(desc)#\(dup)" }
            seenThisBlock.insert(key)
            let now = Bytes(inB: inB, outB: outB)
            let last = lastConn[key]?.bytes
            lastConn[key] = ConnState(bytes: now, lastBlock: blockNumber)
            guard primed else { return }
            var d = Bytes()
            if let last {
                d.inB = inB >= last.inB ? inB - last.inB : 0
                d.outB = outB >= last.outB ? outB - last.outB : 0
            } else {
                d = now // a connection opened since the previous sample
            }
            guard d.inB > 0 || d.outB > 0 else { return }
            pendingPid[currentPid, default: Bytes()].inB += d.inB
            pendingPid[currentPid, default: Bytes()].outB += d.outB
            let host = Self.host(from: remote, v6: proto.hasSuffix("6"))
            let k = DestKey(pid: currentPid, host: host, proto: Self.protoLabel(proto))
            pendingDest[k, default: Bytes()].inB += d.inB
            pendingDest[k, default: Bytes()].outB += d.outB
        } else if let dot = desc.lastIndex(of: "."), let pid = pid_t(desc[desc.index(after: dot)...]) {
            currentPid = pid  // process summary row; bytes are derived from its connections
        }
    }

    private func endBlock() {
        currentPid = -1
        guard blockHasRows else { return }
        blockHasRows = false
        // Forget connections not reported for ~30 samples (closed). Keeping them a while prevents a
        // socket that is listed intermittently from being re-counted from its lifetime total.
        blockNumber += 1
        if blockNumber % 10 == 0 {
            let cutoff = blockNumber - 30
            lastConn = lastConn.filter { $0.value.lastBlock >= cutoff }
        }
        seenThisBlock.removeAll(keepingCapacity: true)
        primed = true
    }

    /// 1 PiB: far above any real socket counter, low enough that summing thousands can't overflow UInt64.
    static let maxCounter: UInt64 = 1 << 50

    /// Connection rows start with a protocol token such as "tcp4 ", "udp6 ", "quic4 ".
    static func isConnectionRow(_ d: String) -> Bool {
        for p in ["tcp4 ", "tcp6 ", "udp4 ", "udp6 ", "quic4 ", "quic6 ", "quic ", "tcp ", "udp "] where d.hasPrefix(p) { return true }
        return false
    }

    static func host(from remote: String, v6: Bool) -> String {
        if remote.hasPrefix("*") { return "*" }
        var s = Substring(remote)
        if v6 {
            if let dot = s.lastIndex(of: ".") { s = s[..<dot] }
        } else if let colon = s.lastIndex(of: ":") {
            s = s[..<colon]
        }
        if let pct = s.firstIndex(of: "%") { s = s[..<pct] }
        return String(s)
    }

    static func protoLabel(_ p: String) -> String {
        if p.hasPrefix("quic") { return "QUIC" }
        if p.hasPrefix("tcp") { return "TCP" }
        if p.hasPrefix("udp") { return "UDP" }
        return p.uppercased()
    }
}
