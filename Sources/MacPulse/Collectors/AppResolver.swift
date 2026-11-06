import Foundation
import Darwin

/// Maps a pid to the *app* that owns it, so "Google Chrome Helper (Renderer)" × 30
/// and WebKit content processes are reported as one row for the app the user knows.
final class AppResolver {
    struct Owner {
        let id: String
        let name: String
        let bundlePath: String?
        let isSystem: Bool
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsibleFor: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private var cache: [pid_t: (start: UInt64, owner: Owner, name: String)] = [:]
    private var bundleNames: [String: String] = [:]

    func processName(pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        if n > 0 { return String(cString: buf) }
        if let p = path(pid: pid) { return (p as NSString).lastPathComponent }
        return "pid \(pid)"
    }

    func path(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// `start` disambiguates pid reuse.
    func resolve(pid: pid_t, start: UInt64) -> (owner: Owner, name: String) {
        if let c = cache[pid], c.start == start { return (c.owner, c.name) }
        let name = processName(pid: pid)
        let owner = computeOwner(pid: pid, name: name)
        cache[pid] = (start, owner, name)
        return (owner, name)
    }

    func prune(alive: Set<pid_t>) {
        cache = cache.filter { alive.contains($0.key) }
    }

    private func computeOwner(pid: pid_t, name: String) -> Owner {
        let myPath = path(pid: pid)

        // 1) Process lives inside an .app bundle → outermost bundle owns it (helpers, XPC services).
        if let p = myPath, let app = outermostApp(in: p) {
            return owner(forApp: app)
        }

        // 2) System helpers (e.g. WebKit content, VTDecoder) are attributed to the responsible app.
        //    Command-line tools stay standalone so `node`, `python` etc. are visible on their own.
        let isSystemPath = myPath.map(Self.isSystemPath) ?? true
        if isSystemPath, let fn = responsibleFor {
            let r = fn(pid)
            if r > 0, r != pid, let rp = path(pid: r), let app = outermostApp(in: rp) {
                return owner(forApp: app)
            }
        }

        if pid == 0 { return Owner(id: "proc:kernel_task", name: "kernel_task", bundlePath: nil, isSystem: true) }
        return Owner(id: "proc:" + name, name: name, bundlePath: nil, isSystem: isSystemPath)
    }

    private func owner(forApp app: String) -> Owner {
        let name: String
        if let cached = bundleNames[app] {
            name = cached
        } else {
            let info = Bundle(path: app)?.localizedInfoDictionary ?? Bundle(path: app)?.infoDictionary
            name = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            bundleNames[app] = name
        }
        return Owner(id: app, name: name, bundlePath: app, isSystem: app.hasPrefix("/System/"))
    }

    private func outermostApp(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func isSystemPath(_ p: String) -> Bool {
        p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/")
            || p.hasPrefix("/sbin/") || p.hasPrefix("/Library/Apple/")
    }
}
