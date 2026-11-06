import Foundation

/// Read-only MCP tools. Every tool only *reads*; see MCPServer for the security model.
enum Tools {
    // MARK: - Definitions

    private static let rangeSchema: [String: Any] = [
        "type": "string", "enum": ["1h", "today", "24h", "7d", "30d"], "default": "24h",
        "description": "Time window: last hour, since midnight, last 24 hours, 7 days or 30 days.",
    ]
    private static let readOnly: [String: Any] = [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
    ]

    static var definitions: [[String: Any]] {
        [
            tool("get_live_status", "Live status (now)",
                 "Current CPU, memory, battery/power and network throughput, plus the apps using the most energy and memory right now. Measures over a short window.",
                 ["window_seconds": ["type": "number", "minimum": 1, "maximum": 5, "default": 1,
                                     "description": "Measurement window in seconds (1–5)."]]),
            tool("get_battery", "Battery details",
                 "Battery charge, charging state, time remaining, whole-system power draw, battery health (capacity vs design), cycle count, voltage, current, temperature and charger wattage.", [:]),
            tool("get_memory", "Memory details",
                 "Memory breakdown (app, wired, compressed, cached, free), swap, memory pressure, and the apps using the most memory right now.", [:]),
            tool("get_top_apps", "Top apps (history)",
                 "Ranks apps over a time window by energy, energy used on battery, CPU time, network traffic or peak memory. Helper processes are grouped under their app.",
                 ["range": rangeSchema,
                  "sort_by": ["type": "string", "enum": ["energy", "battery_energy", "cpu", "network", "memory"], "default": "energy"],
                  "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 15]]),
            tool("get_network_destinations", "Network destinations (history)",
                 "Which servers (hostname/IP) apps exchanged the most data with, over a time window. Optionally filter by app name.",
                 ["range": rangeSchema,
                  "app": ["type": "string", "maxLength": 100, "description": "Optional case-insensitive app name filter."],
                  "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 20]]),
            tool("get_history", "System history",
                 "Time series of battery %, system power (W), CPU %, memory % and network bytes, averaged into buckets.",
                 ["range": rangeSchema,
                  "max_points": ["type": "integer", "minimum": 10, "maximum": 300, "default": 96]]),
            tool("get_battery_report", "Battery report",
                 "Battery drain rate (%/hour) while unplugged, hours on battery, average/peak system power, and battery level range over a time window.",
                 ["range": rangeSchema]),
        ]
    }

    private static func tool(_ name: String, _ title: String, _ desc: String, _ props: [String: Any]) -> [String: Any] {
        ["name": name, "title": title, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "additionalProperties": false],
         "annotations": readOnly.merging(["title": title]) { a, _ in a }]
    }

    // MARK: - Dispatch

    static func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "get_live_status": return LiveProbe.status(window: clamp(args["window_seconds"], 1, 5, 1))
        case "get_battery": return battery(BatteryCollector().read())
        case "get_memory": return LiveProbe.memory()
        case "get_top_apps": return try topApps(args)
        case "get_network_destinations": return try destinations(args)
        case "get_history": return try history(args)
        case "get_battery_report": return try batteryReport(args)
        default: throw ToolError(message: "Unknown tool: \(name.prefix(64))")
        }
    }

    // MARK: - History tools

    private static func store() throws -> HistoryStore {
        let s = HistoryStore(readOnly: true)
        guard s.isOpen else { throw ToolError(message: "No history yet. Make sure the MacPulse app is running; it saves history every minute.") }
        return s
    }

    private static func window(_ args: [String: Any]) throws -> (from: Date, to: Date, label: String) {
        let r = args["range"] as? String ?? "24h"
        let now = Date()
        switch r {
        case "1h": return (now.addingTimeInterval(-3600), now, r)
        case "today": return (Calendar.current.startOfDay(for: now), now, r)
        case "24h": return (now.addingTimeInterval(-86400), now, r)
        case "7d": return (now.addingTimeInterval(-7 * 86400), now, r)
        case "30d": return (now.addingTimeInterval(-30 * 86400), now, r)
        default: throw ToolError(message: "Invalid range '\(r.prefix(16))'. Use one of: 1h, today, 24h, 7d, 30d.")
        }
    }

    private static func topApps(_ args: [String: Any]) throws -> [String: Any] {
        let w = try window(args)
        let sort = args["sort_by"] as? String ?? "energy"
        guard ["energy", "battery_energy", "cpu", "network", "memory"].contains(sort) else {
            throw ToolError(message: "Invalid sort_by. Use energy, battery_energy, cpu, network or memory.")
        }
        let limit = Int(clamp(args["limit"], 1, 50, 15))
        var apps = try store().topApps(from: w.from, to: w.to, limit: 300)
        let key: (HistoryStore.AppTotal) -> Double = {
            switch sort {
            case "battery_energy": $0.batteryEnergyJ
            case "cpu": $0.cpuS
            case "network": $0.netIn + $0.netOut
            case "memory": $0.memPeak
            default: $0.energyJ
            }
        }
        apps.sort { key($0) > key($1) }
        let totalE = apps.reduce(0) { $0 + $1.energyJ }
        return [
            "range": w.label, "sort_by": sort,
            "note": "Hourly granularity. energy_wh is CPU energy attributed to the app.",
            "total_app_energy_wh": r(totalE / 3600, 3),
            "apps": apps.prefix(limit).map { a -> [String: Any] in
                ["name": a.name, "kind": a.app.hasPrefix("/") ? "app" : "process",
                 "energy_wh": r(a.energyJ / 3600, 3), "energy_on_battery_wh": r(a.batteryEnergyJ / 3600, 3),
                 "energy_share_pct": totalE > 0 ? r(a.energyJ / totalE * 100, 1) : 0,
                 "cpu_seconds": r(a.cpuS, 1), "downloaded_bytes": Int(clamping: a.netIn),
                 "uploaded_bytes": Int(clamping: a.netOut), "peak_memory_bytes": Int(clamping: a.memPeak)]
            },
        ]
    }

    static var shareDestinations: Bool {
        UserDefaults.standard.object(forKey: "mcpShareDestinations") as? Bool ?? true
    }

    private static func destinations(_ args: [String: Any]) throws -> [String: Any] {
        guard shareDestinations else {
            throw ToolError(message: "The user has disabled sharing server addresses with AI assistants (MacPulse → Settings → AI / MCP).")
        }
        let w = try window(args)
        let limit = Int(clamp(args["limit"], 1, 50, 20))
        let filter = (args["app"] as? String).map { String($0.prefix(100)).lowercased() }
        var list = try store().topDestinations(from: w.from, to: w.to, limit: 500)
        if let f = filter, !f.isEmpty { list = list.filter { $0.app.lowercased().contains(f) } }
        return [
            "range": w.label,
            "note": "Bytes exchanged with each remote server, per app. host is reverse-DNS when available.",
            "destinations": list.prefix(limit).map { d -> [String: Any] in
                ["app": d.app, "address": d.host, "host": d.label == d.host ? NSNull() : d.label as Any,
                 "downloaded_bytes": Int(clamping: d.bytesIn), "uploaded_bytes": Int(clamping: d.bytesOut)]
            },
        ]
    }

    private static func history(_ args: [String: Any]) throws -> [String: Any] {
        let w = try window(args)
        let maxPoints = Int(clamp(args["max_points"], 10, 300, 96))
        let span = max(60, Int(w.to.timeIntervalSince(w.from)))
        let bucket = max(60, (span / maxPoints + 59) / 60 * 60)
        let pts = try store().series(from: w.from, to: w.to, bucket: bucket)
        let iso = ISO8601DateFormatter()
        return [
            "range": w.label, "bucket_seconds": bucket,
            "points": pts.map { p -> [String: Any] in
                ["time": iso.string(from: Date(timeIntervalSince1970: TimeInterval(p.ts))),
                 "battery_pct": p.battery.map { r($0, 1) } as Any? ?? NSNull(),
                 "system_power_w": p.sysW.map { r($0, 2) } as Any? ?? NSNull(),
                 "cpu_pct": r(p.cpu, 1), "memory_pct": r(p.mem, 1),
                 "downloaded_bytes": Int(clamping: p.netIn), "uploaded_bytes": Int(clamping: p.netOut),
                 "on_ac_power": p.onAC]
            },
        ]
    }

    private static func batteryReport(_ args: [String: Any]) throws -> [String: Any] {
        let w = try window(args)
        let raw = try store().series(from: w.from, to: w.to, bucket: 60)
        var drop = 0.0, secs = 0.0, pw = [Double]()
        for (a, b) in zip(raw, raw.dropFirst()) where !a.onAC && !b.onAC && b.ts - a.ts <= 300 {
            secs += Double(b.ts - a.ts)
            if let ba = a.battery, let bb = b.battery, bb < ba { drop += ba - bb }
        }
        for p in raw { if let v = p.sysW { pw.append(v) } }
        let levels = raw.compactMap(\.battery)
        return [
            "range": w.label,
            "minutes_recorded": raw.count,
            "hours_on_battery": r(secs / 3600, 2),
            "drain_pct_per_hour": secs > 600 ? r(drop / (secs / 3600), 2) as Any : NSNull(),
            "estimated_full_battery_hours": (secs > 600 && drop > 0) ? r(100 / (drop / (secs / 3600)), 1) as Any : NSNull(),
            "avg_system_power_w": pw.isEmpty ? NSNull() : r(pw.reduce(0, +) / Double(pw.count), 2) as Any,
            "peak_system_power_w": pw.max().map { r($0, 2) } as Any? ?? NSNull(),
            "battery_min_pct": levels.min().map { r($0, 1) } as Any? ?? NSNull(),
            "battery_max_pct": levels.max().map { r($0, 1) } as Any? ?? NSNull(),
            "note": "Drain is computed only from consecutive minutes on battery power.",
        ]
    }

    // MARK: - Shared formatting

    static func battery(_ b: BatteryInfo) -> [String: Any] {
        guard b.present else { return ["present": false] }
        return [
            "present": true, "charge_pct": r(b.percent * 100, 1),
            "state": b.fullyCharged ? "full" : b.isCharging ? "charging" : b.externalConnected ? "ac_not_charging" : "discharging",
            "time_remaining_minutes": b.timeRemainingMin as Any? ?? NSNull(),
            "system_power_w": b.systemPowerW.map { r($0, 2) } as Any? ?? NSNull(),
            "battery_power_w": r(b.batteryPowerW, 2),
            "health_pct": r(b.health * 100, 1), "cycle_count": b.cycleCount,
            "design_capacity_mah": b.designCapacity, "full_charge_capacity_mah": b.fullChargeCapacity,
            "voltage_v": r(b.voltageV, 2), "current_a": r(b.amperageA, 2),
            "temperature_c": b.temperatureC.map { r($0, 1) } as Any? ?? NSNull(),
            "adapter_w": b.adapterWatts as Any? ?? NSNull(),
        ]
    }

    /// Rounded number that serialises cleanly ("97.4", not "97.400000000000006").
    static func r(_ v: Double, _ digits: Int) -> NSNumber {
        guard v.isFinite else { return 0 }
        return NSDecimalNumber(string: String(format: "%.\(digits)f", v), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func clamp(_ any: Any?, _ lo: Double, _ hi: Double, _ def: Double) -> Double {
        let v = (any as? NSNumber)?.doubleValue ?? def
        return v.isFinite ? min(max(v, lo), hi) : def
    }
}

/// On-demand live measurement for the MCP process (independent of the running app).
enum LiveProbe {
    struct AppAgg { var name: String; var cpu = 0.0; var watts = 0.0; var mem: UInt64 = 0; var wake = 0.0; var procs = 0 }

    private static func aggregate(_ samples: [ProcessCollector.Sample], elapsed: Double) -> [AppAgg] {
        var apps: [String: AppAgg] = [:]
        for p in samples {
            var a = apps[p.owner.id] ?? AppAgg(name: p.owner.name)
            a.cpu += Double(p.cpuNs) / 1e9 / elapsed * 100
            a.watts += Double(p.energyNj) / 1e9 / elapsed
            a.mem += p.footprint
            a.wake += Double(p.wakeups) / elapsed
            a.procs += 1
            apps[p.owner.id] = a
        }
        return Array(apps.values)
    }

    static func status(window: Double) -> [String: Any] {
        let sys = SystemCollector(), procs = ProcessCollector(), ifs = InterfaceCollector()
        _ = sys.cpu(); _ = procs.sample(); _ = ifs.sample(elapsed: 0)
        let t0 = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: window)
        let el = ProcessInfo.processInfo.systemUptime - t0
        let cpu = sys.cpu(), mem = sys.memory(), bat = BatteryCollector().read()
        let interfaces = ifs.sample(elapsed: el)
        let apps = aggregate(procs.sample(), elapsed: el)
        var down = 0.0, up = 0.0
        for i in interfaces where InterfaceCollector.isPhysical(i.bsdName) { down += i.inRate; up += i.outRate }
        let local = LocalAddress.primary()
        func row(_ a: AppAgg) -> [String: Any] {
            ["name": a.name, "cpu_pct": Tools.r(a.cpu, 1), "energy_w": Tools.r(a.watts, 3),
             "memory_bytes": a.mem, "wakeups_per_s": Tools.r(a.wake, 0), "processes": a.procs]
        }
        return [
            "measured_seconds": Tools.r(el, 2),
            "cpu": ["usage_pct": Tools.r(cpu.usage * 100, 1), "user_pct": Tools.r(cpu.user * 100, 1),
                    "system_pct": Tools.r(cpu.system * 100, 1), "cores": cpu.cores, "load_avg_1m": Tools.r(cpu.load1, 2)],
            "memory": ["used_bytes": mem.used, "total_bytes": mem.total, "used_pct": Tools.r(mem.usedFraction * 100, 1),
                       "pressure": ["normal", "warning", "", "critical"][max(0, min(3, mem.pressure.rawValue - 1))],
                       "swap_used_bytes": mem.swapUsed],
            "battery": Tools.battery(bat),
            "network": ["download_bps": Tools.r(down, 0), "upload_bps": Tools.r(up, 0),
                        "interfaces": interfaces.prefix(6).map { ["name": $0.displayName, "bsd": $0.bsdName,
                                                                  "download_bps": Tools.r($0.inRate, 0), "upload_bps": Tools.r($0.outRate, 0)] },
                        "local_ip": local?.ip as Any? ?? NSNull()],
            "top_energy_apps": apps.sorted { $0.watts > $1.watts }.prefix(10).map(row),
            "top_memory_apps": apps.sorted { $0.mem > $1.mem }.prefix(10).map(row),
            "note": "energy_w is CPU energy per app from kernel counters; battery.system_power_w is the whole machine. Per-app network history is in get_top_apps / get_network_destinations.",
        ]
    }

    static func memory() -> [String: Any] {
        let m = SystemCollector().memory()
        let procs = ProcessCollector()
        _ = procs.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let apps = aggregate(procs.sample(), elapsed: 0.3).sorted { $0.mem > $1.mem }
        return [
            "total_bytes": m.total, "used_bytes": m.used, "used_pct": Tools.r(m.usedFraction * 100, 1),
            "app_bytes": m.app, "wired_bytes": m.wired, "compressed_bytes": m.compressed,
            "cached_files_bytes": m.cached, "free_bytes": m.free,
            "swap_used_bytes": m.swapUsed, "swap_total_bytes": m.swapTotal,
            "pressure": ["normal", "warning", "", "critical"][max(0, min(3, m.pressure.rawValue - 1))],
            "top_apps": apps.prefix(15).map { ["name": $0.name, "memory_bytes": $0.mem, "processes": $0.procs] },
            "note": "memory_bytes is physical footprint (same as Activity Monitor). Cached files are reclaimable; pressure and swap are the real signals.",
        ]
    }
}
