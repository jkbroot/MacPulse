import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Durable history in a small SQLite file (WAL). Written once per minute in a single transaction;
/// minute-level system rows for 30 days, hourly per-app/per-destination rows for 180 days.
final class HistoryStore {
    struct SystemRow { let ts: Int; let battery: Double?; let charging: Bool; let onAC: Bool; let sysW: Double?; let cpu: Double; let mem: Double; let netIn: Double; let netOut: Double }
    struct AppRow { let hour: Int; let app: String; let name: String; var energyJ: Double; var cpuS: Double; var netIn: Double; var netOut: Double; var memPeak: Double; var batteryEnergyJ: Double }
    struct DestRow { let hour: Int; let app: String; let host: String; var label: String; var bytesIn: Double; var bytesOut: Double }

    struct AppTotal: Identifiable, Hashable { var id: String { app }; let app: String; let name: String; let energyJ: Double; let cpuS: Double; let netIn: Double; let netOut: Double; let memPeak: Double; let batteryEnergyJ: Double }
    struct DestTotal: Identifiable, Hashable { var id: String { host + app }; let host: String; let label: String; let app: String; let bytesIn: Double; let bytesOut: Double }
    struct SeriesPoint: Identifiable, Hashable { var id: Int { ts }; let ts: Int; let battery: Double?; let sysW: Double?; let cpu: Double; let mem: Double; let netIn: Double; let netOut: Double; let onAC: Bool }

    private var db: OpaquePointer?
    let url: URL

    let readOnly: Bool

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPulse", isDirectory: true)
    }

    /// Read-only handle for the MCP server: the file is opened with SQLITE_OPEN_READONLY and
    /// `PRAGMA query_only`, so even a bug in a query cannot modify the history.
    init(readOnly: Bool) {
        self.readOnly = true
        url = Self.defaultDirectory.appendingPathComponent("history.sqlite")
        guard FileManager.default.fileExists(atPath: url.path),
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil; return
        }
        sqlite3_busy_timeout(db, 2000)
        exec("PRAGMA query_only=ON;")
    }

    var isOpen: Bool { db != nil }

    init() {
        readOnly = false
        let dir = Self.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The history reveals which servers each app talked to: owner-only access (0700 / 0600),
        // including the -wal/-shm side files SQLite creates later inside this directory.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("nettop.pid")) // obsolete (pre-guard builds)
        url = dir.appendingPathComponent("history.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil; return
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        exec("""
        CREATE TABLE IF NOT EXISTS sys_min(ts INTEGER PRIMARY KEY, batt REAL, charging INTEGER, ac INTEGER,
            sys_w REAL, cpu REAL, mem REAL, net_in REAL, net_out REAL);
        CREATE TABLE IF NOT EXISTS app_hour(hour INTEGER, app TEXT, name TEXT, energy_j REAL, cpu_s REAL,
            net_in REAL, net_out REAL, mem_peak REAL, batt_energy_j REAL, PRIMARY KEY(hour, app)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS dest_hour(hour INTEGER, app TEXT, host TEXT, label TEXT, bytes_in REAL,
            bytes_out REAL, PRIMARY KEY(hour, app, host)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS app_hour_by_app ON app_hour(app, hour);
        """)
        for f in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f)
        }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK ? st : nil
    }

    // MARK: - Writes

    func write(system: [SystemRow], apps: [AppRow], dests: [DestRow]) {
        guard db != nil, !readOnly, !(system.isEmpty && apps.isEmpty && dests.isEmpty) else { return }
        exec("BEGIN")
        if let st = prepare("INSERT OR REPLACE INTO sys_min VALUES(?,?,?,?,?,?,?,?,?)") {
            for r in system {
                sqlite3_bind_int64(st, 1, Int64(r.ts))
                if let b = r.battery { sqlite3_bind_double(st, 2, b) } else { sqlite3_bind_null(st, 2) }
                sqlite3_bind_int(st, 3, r.charging ? 1 : 0)
                sqlite3_bind_int(st, 4, r.onAC ? 1 : 0)
                if let w = r.sysW { sqlite3_bind_double(st, 5, w) } else { sqlite3_bind_null(st, 5) }
                sqlite3_bind_double(st, 6, r.cpu)
                sqlite3_bind_double(st, 7, r.mem)
                sqlite3_bind_double(st, 8, r.netIn)
                sqlite3_bind_double(st, 9, r.netOut)
                sqlite3_step(st); sqlite3_reset(st)
            }
            sqlite3_finalize(st)
        }
        if let st = prepare("""
            INSERT INTO app_hour VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(hour, app) DO UPDATE SET
            name=excluded.name, energy_j=energy_j+excluded.energy_j, cpu_s=cpu_s+excluded.cpu_s,
            net_in=net_in+excluded.net_in, net_out=net_out+excluded.net_out,
            mem_peak=MAX(mem_peak, excluded.mem_peak), batt_energy_j=batt_energy_j+excluded.batt_energy_j
            """) {
            for r in apps {
                sqlite3_bind_int64(st, 1, Int64(r.hour))
                sqlite3_bind_text(st, 2, r.app, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(st, 3, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(st, 4, r.energyJ)
                sqlite3_bind_double(st, 5, r.cpuS)
                sqlite3_bind_double(st, 6, r.netIn)
                sqlite3_bind_double(st, 7, r.netOut)
                sqlite3_bind_double(st, 8, r.memPeak)
                sqlite3_bind_double(st, 9, r.batteryEnergyJ)
                sqlite3_step(st); sqlite3_reset(st)
            }
            sqlite3_finalize(st)
        }
        if let st = prepare("""
            INSERT INTO dest_hour VALUES(?,?,?,?,?,?) ON CONFLICT(hour, app, host) DO UPDATE SET
            label=CASE WHEN excluded.label<>excluded.host THEN excluded.label ELSE label END,
            bytes_in=bytes_in+excluded.bytes_in, bytes_out=bytes_out+excluded.bytes_out
            """) {
            for r in dests {
                sqlite3_bind_int64(st, 1, Int64(r.hour))
                sqlite3_bind_text(st, 2, r.app, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(st, 3, r.host, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(st, 4, r.label, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(st, 5, r.bytesIn)
                sqlite3_bind_double(st, 6, r.bytesOut)
                sqlite3_step(st); sqlite3_reset(st)
            }
            sqlite3_finalize(st)
        }
        exec("COMMIT")
    }

    func prune(now: Date = Date()) {
        guard !readOnly else { return }
        let t = Int(now.timeIntervalSince1970)
        exec("DELETE FROM sys_min WHERE ts < \(t - 30 * 86400)")
        exec("DELETE FROM app_hour WHERE hour < \(t - 180 * 86400)")
        exec("DELETE FROM dest_hour WHERE hour < \(t - 90 * 86400)")
    }

    func clearAll() {
        guard !readOnly else { return }
        exec("DELETE FROM sys_min; DELETE FROM app_hour; DELETE FROM dest_hour; VACUUM;")
    }

    // MARK: - Reads

    func series(from: Date, to: Date, bucket: Int) -> [SeriesPoint] {
        guard let st = prepare("""
            SELECT (ts/?1)*?1 AS b, AVG(batt), AVG(sys_w), AVG(cpu), AVG(mem), SUM(net_in), SUM(net_out), MIN(ac)
            FROM sys_min WHERE ts BETWEEN ?2 AND ?3 GROUP BY b ORDER BY b
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(max(bucket, 60)))
        sqlite3_bind_int64(st, 2, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(st, 3, Int64(to.timeIntervalSince1970))
        var out: [SeriesPoint] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(SeriesPoint(
                ts: Int(sqlite3_column_int64(st, 0)),
                battery: sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : sqlite3_column_double(st, 1),
                sysW: sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : sqlite3_column_double(st, 2),
                cpu: sqlite3_column_double(st, 3), mem: sqlite3_column_double(st, 4),
                netIn: sqlite3_column_double(st, 5), netOut: sqlite3_column_double(st, 6),
                onAC: sqlite3_column_int(st, 7) == 1))
        }
        return out
    }

    func topApps(from: Date, to: Date, limit: Int = 40) -> [AppTotal] {
        guard let st = prepare("""
            SELECT app, MAX(name), SUM(energy_j), SUM(cpu_s), SUM(net_in), SUM(net_out), MAX(mem_peak), SUM(batt_energy_j)
            FROM app_hour WHERE hour BETWEEN ?1 AND ?2 GROUP BY app ORDER BY SUM(energy_j) DESC LIMIT ?3
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(from.timeIntervalSince1970) / 3600 * 3600)
        sqlite3_bind_int64(st, 2, Int64(to.timeIntervalSince1970))
        sqlite3_bind_int(st, 3, Int32(limit))
        var out: [AppTotal] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(AppTotal(app: text(st, 0), name: text(st, 1), energyJ: sqlite3_column_double(st, 2),
                                cpuS: sqlite3_column_double(st, 3), netIn: sqlite3_column_double(st, 4),
                                netOut: sqlite3_column_double(st, 5), memPeak: sqlite3_column_double(st, 6),
                                batteryEnergyJ: sqlite3_column_double(st, 7)))
        }
        return out
    }

    func topDestinations(from: Date, to: Date, limit: Int = 25) -> [DestTotal] {
        guard let st = prepare("""
            SELECT host, MAX(label), (SELECT a.name FROM app_hour a WHERE a.app = d.app LIMIT 1),
                   SUM(bytes_in), SUM(bytes_out)
            FROM dest_hour d WHERE hour BETWEEN ?1 AND ?2 AND host <> '*'
            GROUP BY host, app ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC LIMIT ?3
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(from.timeIntervalSince1970) / 3600 * 3600)
        sqlite3_bind_int64(st, 2, Int64(to.timeIntervalSince1970))
        sqlite3_bind_int(st, 3, Int32(limit))
        var out: [DestTotal] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(DestTotal(host: text(st, 0), label: text(st, 1), app: text(st, 2),
                                 bytesIn: sqlite3_column_double(st, 3), bytesOut: sqlite3_column_double(st, 4)))
        }
        return out
    }

    func fileSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let wal = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return ((attrs?[.size] as? NSNumber)?.uint64Value ?? 0) + ((wal?[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }
}
