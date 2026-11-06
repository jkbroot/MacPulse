import Darwin

/// A tiny supervisor mode of the MacPulse binary itself: `MacPulse --nettop-guard <parentPid> <nettop args…>`.
///
/// Why: nettop never exits on its own when its reader disappears — with a closed pty or EOF on stdin it
/// busy-loops at >100 % CPU (measured). If MacPulse were force-killed or crashed, an orphaned nettop
/// would silently burn the battery. The guard waits on kqueue (zero polling, zero CPU) for either the
/// parent or nettop to exit, or for SIGTERM, and always takes nettop down with it.
enum NettopGuard {
    static func run(parent: pid_t, nettopArgs: [String]) -> Never {
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        // Spawn nettop inheriting our stdin/stdout (the pty slave) with default signal handling.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for s in [SIGTERM, SIGHUP, SIGINT, SIGPIPE] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))
        let args = ["/usr/bin/nettop"] + nettopArgs
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [strdup("TERM=dumb"), strdup("PATH=/usr/bin:/bin"), nil]
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/usr/bin/nettop", nil, &attr, &argv, &env)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else { exit(2) }

        func finish(_ code: Int32) -> Never {
            kill(child, SIGKILL)
            var st: Int32 = 0
            waitpid(child, &st, 0)
            exit(code)
        }

        let kq = kqueue()
        var changes = [
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
            kevent(ident: UInt(child), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
            kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGHUP), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
        ]
        if kevent(kq, &changes, Int32(changes.count), nil, 0, nil) < 0 { finish(3) }
        // Parent may already be gone (race between spawn and registration).
        if getppid() != parent || kill(parent, 0) != 0 { finish(0) }

        var ev = kevent()
        while true {
            let n = kevent(kq, nil, 0, &ev, 1, nil)
            if n < 0 { if errno == EINTR { continue }; finish(4) }
            if n == 0 { continue }
            if ev.filter == Int16(EVFILT_PROC) && ev.ident == UInt(child) {
                var st: Int32 = 0
                waitpid(child, &st, 0)
                exit(1)
            }
            finish(0) // parent exited, or we were asked to stop
        }
    }
}
