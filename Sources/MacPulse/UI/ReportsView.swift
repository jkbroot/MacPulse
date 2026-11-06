import SwiftUI
import Charts
import AppKit

enum ReportRange: String, CaseIterable, Identifiable {
    case today, day, week, month
    var id: String { rawValue }
    var title: String {
        switch self { case .today: T("اليوم", "Today"); case .day: T("24 ساعة", "24 h"); case .week: T("7 أيام", "7 days"); case .month: T("30 يوم", "30 days") }
    }
    var interval: (Date, Date) {
        let now = Date()
        switch self {
        case .today: return (Calendar.current.startOfDay(for: now), now)
        case .day: return (now.addingTimeInterval(-86400), now)
        case .week: return (now.addingTimeInterval(-7 * 86400), now)
        case .month: return (now.addingTimeInterval(-30 * 86400), now)
        }
    }
    var bucket: Int {
        switch self { case .today, .day: 600; case .week: 3600; case .month: 3 * 3600 }
    }
}

struct ReportData {
    var series: [HistoryStore.SeriesPoint] = []
    var apps: [HistoryStore.AppTotal] = []
    var dests: [HistoryStore.DestTotal] = []
    var batteryHours: Double = 0
    var drainPerHour: Double?
    var avgPowerW: Double?
    var totalIn: Double = 0
    var totalOut: Double = 0
}


extension ReportData {
    static func load(store: HistoryStore, range r: ReportRange) -> ReportData {
        let (from, to) = r.interval
        var d = ReportData()
        d.series = store.series(from: from, to: to, bucket: r.bucket)
        d.apps = store.topApps(from: from, to: to)
        d.dests = store.topDestinations(from: from, to: to)
        // Battery drain: only consecutive points that are both on battery.
        let raw = store.series(from: from, to: to, bucket: 60)
        var drop = 0.0, secs = 0.0, wSum = 0.0, wN = 0.0
        for (a, b) in zip(raw, raw.dropFirst()) where !a.onAC && !b.onAC && b.ts - a.ts <= 300 {
            secs += Double(b.ts - a.ts)
            if let ba = a.battery, let bb = b.battery, bb < ba { drop += ba - bb }
        }
        for p in raw { if let w = p.sysW { wSum += w; wN += 1 } }
        d.batteryHours = secs / 3600
        d.drainPerHour = secs > 600 ? drop / (secs / 3600) : nil
        d.avgPowerW = wN > 0 ? wSum / wN : nil
        d.totalIn = raw.reduce(0) { $0 + $1.netIn }
        d.totalOut = raw.reduce(0) { $0 + $1.netOut }
        return d
    }
}

struct ReportsView: View {
    // Not an observer of live data: the charts here re-render only when the range or data changes.
    private let sampler = Monitor.shared.sampler
    @State private var range: ReportRange = .today
    @State private var data = ReportData()
    @State private var loading = true
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $range) {
                ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if loading && data.series.isEmpty {
                ProgressView().padding(30)
            } else if data.series.isEmpty && data.apps.isEmpty {
                Card { EmptyHint(text: T("لا توجد بيانات كافية بعد — يتم حفظ السجل كل دقيقة.", "Not enough data yet — history is saved every minute.")) }
            } else {
                summary
                batteryChart
                topEnergy
                networkChart
                topNetwork
                topDestinations
                HStack {
                    Button { exportCSV() } label: { Label(T("تصدير التقرير CSV", "Export CSV report"), systemImage: "square.and.arrow.up") }
                        .glassButton()
                    Spacer()
                    if let exportMessage { Text(exportMessage).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: range) { load() }
    }

    private func load() {
        loading = true
        let r = range
        sampler.query({ store in ReportData.load(store: store, range: r)         }) { d in
            data = d
            loading = false
        }
    }

    // MARK: Sections

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            mini(T("متوسط الاستهلاك", "Avg power"), data.avgPowerW.map { Fmt.watts($0) } ?? "—", Palette.power)
            mini(T("تصريف البطارية", "Battery drain"), data.drainPerHour.map { String(format: T("%.1f%%/س", "%.1f%%/h"), $0) } ?? "—", Palette.battery)
            mini(T("على البطارية", "On battery"), String(format: T("%.1f س", "%.1f h"), data.batteryHours), Palette.battery)
            mini(T("تنزيل", "Downloaded"), Fmt.bytes(data.totalIn), Palette.down)
            mini(T("رفع", "Uploaded"), Fmt.bytes(data.totalOut), Palette.up)
            mini(T("طاقة التطبيقات", "App energy"), Fmt.energy(data.apps.reduce(0) { $0 + $1.energyJ }), Palette.power)
        }
    }

    private func mini(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(Radius.inner + 2, tint: c)
    }

    private var batteryChart: some View {
        Card(title: T("البطارية والطاقة", "Battery & power"), symbol: "battery.100.bolt", tint: Palette.battery) {
            Chart {
                ForEach(data.series) { p in
                    if let b = p.battery {
                        LineMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))), y: .value("%", b), series: .value("s", "batt"))
                            .foregroundStyle(Palette.battery).interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.caption2) } }
            } }
            .chartXAxis { xAxis }
            .environment(\.layoutDirection, .leftToRight)
            .frame(height: 80)

            Chart {
                ForEach(data.series) { p in
                    if let w = p.sysW {
                        AreaMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))), y: .value("W", w))
                            .foregroundStyle(LinearGradient(colors: [Palette.power.opacity(0.6), Palette.power.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .trailing) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))W").font(.caption2) } }
            } }
            .chartXAxis { xAxis }
            .environment(\.layoutDirection, .leftToRight)
            .frame(height: 70)
        }
    }

    private var networkChart: some View {
        Card(title: T("استخدام الشبكة", "Network usage"), symbol: "chart.bar.fill", tint: Palette.down) {
            Chart {
                ForEach(data.series) { p in
                    let t = Date(timeIntervalSince1970: TimeInterval(p.ts))
                    BarMark(x: .value("t", t, unit: range == .month ? .hour : .minute), y: .value("B", p.netIn))
                        .foregroundStyle(by: .value("k", T("تنزيل", "Download")))
                    BarMark(x: .value("t", t, unit: range == .month ? .hour : .minute), y: .value("B", p.netOut))
                        .foregroundStyle(by: .value("k", T("رفع", "Upload")))
                }
            }
            .chartForegroundStyleScale([T("تنزيل", "Download"): Palette.down, T("رفع", "Upload"): Palette.up])
            .chartLegend(position: .top, alignment: .trailing)
            .chartYAxis { AxisMarks(position: .trailing) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)).font(.caption2) } }
            } }
            .chartXAxis { xAxis }
            .environment(\.layoutDirection, .leftToRight)
            .frame(height: 110)
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisValueLabel(format: range == .today || range == .day ? .dateTime.hour() : .dateTime.day().month(.abbreviated))
        }
    }

    private var topEnergy: some View {
        Card(title: T("أكثر التطبيقات استهلاكاً للطاقة", "Top energy apps"), symbol: "flame.fill", tint: Palette.power) {
            let list = data.apps.filter { $0.energyJ > 0 }.prefix(12)
            let maxE = list.first?.energyJ ?? 1
            ForEach(Array(list)) { a in
                RankedRow(iconPath: a.app.hasPrefix("/") ? a.app : nil, isSystem: !a.app.hasPrefix("/"), name: a.name,
                          value: Fmt.energy(a.energyJ),
                          secondary: a.batteryEnergyJ > 0 ? T("من البطارية ", "on battery ") + Fmt.energy(a.batteryEnergyJ) : "CPU \(Fmt.seconds(a.cpuS))",
                          fraction: a.energyJ / maxE, tint: Palette.power)
            }
        }
    }

    private var topNetwork: some View {
        Card(title: T("أكثر التطبيقات استخداماً للشبكة", "Top network apps"), symbol: "network", tint: Palette.down) {
            let list = data.apps.filter { $0.netIn + $0.netOut > 0 }.sorted { $0.netIn + $0.netOut > $1.netIn + $1.netOut }.prefix(10)
            let maxN = (list.first.map { $0.netIn + $0.netOut }) ?? 1
            if list.isEmpty { EmptyHint(text: T("لا توجد بيانات", "No data")) }
            ForEach(Array(list)) { a in
                RankedRow(iconPath: a.app.hasPrefix("/") ? a.app : nil, isSystem: !a.app.hasPrefix("/"), name: a.name,
                          value: Fmt.bytes(a.netIn + a.netOut),
                          secondary: Fmt.updown(Fmt.bytes(a.netIn), Fmt.bytes(a.netOut)),
                          fraction: (a.netIn + a.netOut) / maxN, tint: Palette.down)
            }
        }
    }

    private var topDestinations: some View {
        Card(title: T("أكثر الوجهات (الخوادم)", "Top destinations (servers)"), symbol: "globe", tint: Palette.up) {
            let list = data.dests.prefix(12)
            if list.isEmpty { EmptyHint(text: T("لا توجد بيانات", "No data")) }
            ForEach(Array(list)) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.label.isEmpty ? d.host : d.label).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text("\(d.app) · \(d.host)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.bytes(d.bytesIn + d.bytesOut)).font(.caption).monospacedDigit()
                }
            }
        }
    }

    // MARK: Export

    private func exportCSV() {
        var csv = "\u{FEFF}" + T("القسم,الاسم,طاقة (Wh),طاقة من البطارية (Wh),وقت المعالج (ث),تنزيل (بايت),رفع (بايت),أعلى ذاكرة (بايت)", "Section,Name,Energy (Wh),Energy on battery (Wh),CPU time (s),Downloaded (bytes),Uploaded (bytes),Peak memory (bytes)") + "\n"
        for a in data.apps {
            csv += T("تطبيق", "App") + ",\(q(a.name)),\(String(format: "%.4f", a.energyJ / 3600)),\(String(format: "%.4f", a.batteryEnergyJ / 3600)),\(Int(clamping: a.cpuS)),\(Int(clamping: a.netIn)),\(Int(clamping: a.netOut)),\(Int(clamping: a.memPeak))\n"
        }
        csv += "\n" + T("الوجهة,العنوان,التطبيق,تنزيل (بايت),رفع (بايت)", "Destination,Address,App,Downloaded (bytes),Uploaded (bytes)") + "\n"
        for d in data.dests { csv += "\(q(d.label)),\(q(d.host)),\(q(d.app)),\(Int(clamping: d.bytesIn)),\(Int(clamping: d.bytesOut))\n" }
        csv += "\n" + T("الوقت,البطارية %,الطاقة (W),المعالج %,الذاكرة %,تنزيل,رفع,على الشاحن", "Time,Battery %,Power (W),CPU %,Memory %,Down,Up,On AC") + "\n"
        let f = ISO8601DateFormatter()
        for p in data.series {
            csv += "\(f.string(from: Date(timeIntervalSince1970: TimeInterval(p.ts)))),\(p.battery.map { String(format: "%.1f", $0) } ?? ""),\(p.sysW.map { String(format: "%.2f", $0) } ?? ""),\(String(format: "%.1f", p.cpu)),\(String(format: "%.1f", p.mem)),\(Int(clamping: p.netIn)),\(Int(clamping: p.netOut)),\(p.onAC ? 1 : 0)\n"
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmm"; df.locale = Locale(identifier: "en_US_POSIX")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPulse-\(range.rawValue)-\(df.string(from: Date())).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = T("تم الحفظ في التنزيلات", "Saved to Downloads")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportMessage = T("فشل الحفظ: ", "Save failed: ") + error.localizedDescription
        }
    }

    private func q(_ s: String) -> String { CSV.cell(s) }
}

enum CSV {
    /// CSV cell: always quoted, and neutralised against spreadsheet formula injection (CWE-1236).
    /// Hostnames come from reverse-DNS (PTR) records, which a remote server's owner fully controls;
    /// a value like `=HYPERLINK(...)` or `@SUM(...)` would otherwise run when opened in Excel/Numbers.
    static func cell(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let f = v.first, "=+-@\t".contains(f) { v = "'" + v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
