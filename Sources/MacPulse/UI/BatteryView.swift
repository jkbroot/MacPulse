import SwiftUI

struct BatteryView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var showAll = false

    var body: some View {
        let s = monitor.snapshot
        let b = s.battery
        VStack(spacing: 12) {
            if b.present {
                Card(tint: Palette.level(1 - b.percent)) {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle().stroke(.primary.opacity(0.08), lineWidth: 10)
                            Circle().trim(from: 0, to: b.percent)
                                .stroke(AngularGradient(colors: [Palette.level(1 - b.percent).opacity(0.6), Palette.level(1 - b.percent)],
                                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * b.percent)),
                                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text(Fmt.percent(b.percent)).font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
                                Image(systemName: b.isCharging ? "bolt.fill" : (b.externalConnected ? "powerplug.fill" : "battery.75percent"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 96, height: 96)

                        VStack(alignment: .leading, spacing: 7) {
                            Text(stateText(b)).font(.system(.headline, design: .rounded))
                            KeyValueRow(key: T("استهلاك الجهاز", "System draw"), value: b.systemPowerW.map { Fmt.watts($0) } ?? "—", tint: Palette.power)
                            KeyValueRow(key: b.batteryPowerW >= 0 ? T("الشحن للبطارية", "Into battery") : T("السحب من البطارية", "From battery"),
                                        value: Fmt.watts(abs(b.batteryPowerW)))
                            if let w = b.adapterWatts { KeyValueRow(key: T("الشاحن", "Adapter"), value: "\(w) W") }
                            if let t = b.timeRemainingMin {
                                KeyValueRow(key: b.isCharging ? T("حتى الامتلاء", "Until full") : T("الوقت المتبقي", "Time left"),
                                            value: Fmt.duration(minutes: t))
                            }
                        }
                    }
                }

                Card(title: T("صحة البطارية", "Battery health"), symbol: "heart.fill", tint: Palette.battery) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.percent(b.health, digits: 1)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(b.health > 0.8 ? Palette.battery : b.health > 0.7 ? Palette.warn : Palette.danger)
                        Spacer()
                        Text(b.health > 0.8 ? T("ممتازة", "Excellent") : b.health > 0.7 ? T("متوسطة", "Fair") : T("تحتاج صيانة", "Service recommended"))
                            .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 4).glassCapsule()
                    }
                    Meter(fraction: b.health, tint: b.health > 0.8 ? Palette.battery : Palette.warn)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow {
                            KeyValueRow(key: T("دورات الشحن", "Cycles"), value: "\(b.cycleCount)")
                            KeyValueRow(key: T("الجهد", "Voltage"), value: String(format: "%.2f V", b.voltageV))
                        }
                        GridRow {
                            KeyValueRow(key: T("السعة الحالية", "Full charge"), value: "\(b.fullChargeCapacity) mAh")
                            KeyValueRow(key: T("سعة التصميم", "Design"), value: "\(b.designCapacity) mAh")
                        }
                        GridRow {
                            KeyValueRow(key: T("المتبقي", "Remaining"), value: "\(b.currentCapacity) mAh")
                            KeyValueRow(key: T("التيار", "Current"), value: String(format: "%.2f A", b.amperageA))
                        }
                        if let t = b.temperatureC {
                            GridRow { KeyValueRow(key: T("الحرارة", "Temperature"), value: String(format: "%.1f°C", t)); Color.clear }
                        }
                    }
                }
            } else {
                Card { EmptyHint(text: T("هذا الجهاز لا يحتوي على بطارية — يتم عرض استهلاك التطبيقات فقط",
                                         "This Mac has no battery — showing app energy only")) }
            }

            Card(title: T("من يستنزف الطاقة؟", "What's using energy?"), symbol: "flame.fill",
                 trailing: T("المجموع ", "Total ") + Fmt.watts(s.appsPowerW), tint: Palette.power) {
                let list = s.apps.filter { $0.powerW > 0.001 }
                let shown = showAll ? Array(list.prefix(40)) : Array(list.prefix(10))
                let total = max(s.appsPowerW, 0.0001)
                if shown.isEmpty { EmptyHint(text: T("يتم جمع البيانات…", "Collecting data…")) }
                ForEach(shown) { a in
                    RankedRow(iconPath: a.bundlePath, isSystem: a.isSystem, name: a.name, value: Fmt.watts(a.powerW),
                              secondary: String(format: "%.0f%%", a.powerW / total * 100),
                              fraction: a.powerW / (shown.first?.powerW ?? 1), tint: Palette.power, expandable: true) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 12) {
                                Label(String(format: "%.1f%% CPU", a.cpuPercent), systemImage: "cpu")
                                Label(String(format: T("%.0f إيقاظ/ث", "%.0f wakeups/s"), a.wakeupsPerSec), systemImage: "alarm")
                                Label(Fmt.bytes(a.memoryBytes), systemImage: "memorychip")
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                            ProcessList(processes: a.processes)
                        }
                    }
                }
                if list.count > 10 {
                    Button(showAll ? T("عرض أقل", "Show less") : T("عرض الكل (\(list.count))", "Show all (\(list.count))")) {
                        withAnimation(.snappy) { showAll.toggle() }
                    }
                    .glassButton().controlSize(.small)
                }
                Footnote(text: T("طاقة كل تطبيق مقاسة من عدادات الطاقة في نواة macOS (طاقة المعالج لكل عملية). الفرق بينها وبين استهلاك الجهاز الكلي يذهب للشاشة وكرت الرسوم والذاكرة والنظام. الإيقاظ/ث = مرات إيقاظ المعالج، وهي سبب رئيسي لاستنزاف البطارية في الخلفية.",
                                 "Per-app energy comes from macOS kernel energy counters (CPU energy per process). The rest of the system draw goes to the display, GPU, memory and OS. Wakeups/s = how often the app wakes the CPU — a major cause of background battery drain.")
                         + (s.unreadableProcesses > 0 ? T(" \(s.unreadableProcesses) عملية نظام محمية لا يمكن قراءتها بدون صلاحيات root.",
                                                          " \(s.unreadableProcesses) protected system processes can't be read without root.") : ""))
            }
        }
    }

    private func stateText(_ b: BatteryInfo) -> String {
        if b.fullyCharged { return T("مشحونة بالكامل", "Fully charged") }
        if b.isCharging { return T("جاري الشحن", "Charging") }
        if b.externalConnected { return T("متصل بالشاحن (لا يشحن)", "On AC (not charging)") }
        return T("تعمل على البطارية", "On battery")
    }
}
