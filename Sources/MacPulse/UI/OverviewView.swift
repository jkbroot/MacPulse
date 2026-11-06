import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let s = monitor.snapshot
        let live = monitor.live
        VStack(spacing: 12) {
            GlassGroup(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    StatTile(title: T("المعالج", "CPU"), value: Fmt.percent(s.cpu.usage),
                             subtitle: T("مستخدم \(Fmt.percent(s.cpu.user)) · نظام \(Fmt.percent(s.cpu.system)) · \(s.cpu.cores) أنوية",
                                         "User \(Fmt.percent(s.cpu.user)) · Sys \(Fmt.percent(s.cpu.system)) · \(s.cpu.cores) cores"),
                             symbol: "cpu", tint: Palette.cpu, series: live.map(\.cpu))
                    StatTile(title: T("الذاكرة", "Memory"), value: Fmt.bytes(s.memory.used),
                             subtitle: T("من \(Fmt.bytes(s.memory.total)) · الضغط \(s.memory.pressure.label)",
                                         "of \(Fmt.bytes(s.memory.total)) · Pressure \(s.memory.pressure.label)"),
                             symbol: "memorychip", tint: Palette.memory, series: live.map(\.mem))
                    StatTile(title: T("استهلاك الطاقة", "Power draw"), value: Fmt.watts(s.battery.systemPowerW ?? s.appsPowerW),
                             subtitle: batterySubtitle(s.battery),
                             symbol: "bolt.fill", tint: Palette.power, series: live.map(\.power))
                    StatTile(title: T("الشبكة", "Network"), value: "↓ " + Fmt.rate(s.netInRate),
                             subtitle: "↑ " + Fmt.rate(s.netOutRate),
                             symbol: "arrow.up.arrow.down", tint: Palette.down,
                             series: live.map(\.netIn), series2: live.map(\.netOut), tint2: Palette.up)
                }
            }

            Card(title: T("أكثر التطبيقات استنزافاً للطاقة الآن", "Top energy users now"), symbol: "flame.fill",
                 trailing: Fmt.watts(s.appsPowerW) + T(" للتطبيقات", " apps"), tint: Palette.power) {
                let top = s.apps.filter { $0.powerW > 0.005 }.prefix(6)
                let maxW = top.first?.powerW ?? 1
                if top.isEmpty { EmptyHint(text: T("يتم جمع البيانات…", "Collecting data…")) }
                ForEach(Array(top)) { a in
                    RankedRow(iconPath: a.bundlePath, isSystem: a.isSystem, name: a.name, value: Fmt.watts(a.powerW),
                              secondary: String(format: "%.0f%% CPU", a.cpuPercent),
                              fraction: a.powerW / maxW, tint: Palette.power, expandable: true) {
                        ProcessList(processes: a.processes)
                    }
                }
            }

            Card(title: T("أكثر التطبيقات استخداماً للشبكة الآن", "Top network users now"), symbol: "network", tint: Palette.down) {
                let top = s.apps.filter { $0.netTotalRate > 0 }.sorted { $0.netTotalRate > $1.netTotalRate }.prefix(4)
                let maxR = top.first?.netTotalRate ?? 1
                if top.isEmpty { EmptyHint(text: T("لا توجد حركة شبكة ملحوظة", "No notable network activity")) }
                ForEach(Array(top)) { a in
                    RankedRow(iconPath: a.bundlePath, isSystem: a.isSystem, name: a.name,
                              value: Fmt.rate(a.netTotalRate),
                              secondary: Fmt.updown(Fmt.rate(a.netInRate, compact: true), Fmt.rate(a.netOutRate, compact: true)),
                              fraction: a.netTotalRate / maxR, tint: Palette.down)
                }
            }
        }
    }

    private func batterySubtitle(_ b: BatteryInfo) -> String {
        guard b.present else { return T("لا توجد بطارية", "No battery") }
        var s = T("البطارية", "Battery") + " " + Fmt.percent(b.percent)
        if b.isCharging { s += T(" · تشحن", " · charging") }
        else if b.externalConnected { s += T(" · على الشاحن", " · on AC") }
        else if let t = b.timeRemainingMin { s += T(" · متبقي ", " · ") + Fmt.duration(minutes: t) + T("", " left") }
        return s
    }
}
