import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let s = monitor.snapshot
        let m = s.memory
        VStack(spacing: 12) {
            Card(tint: Palette.memory) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("مستخدم", "Used")).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.bytes(m.used)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(T("من ", "of ") + Fmt.bytes(m.total)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(T("ضغط الذاكرة", "Memory pressure")).font(.caption).foregroundStyle(.secondary)
                        Text(m.pressure.label).font(.system(.headline, design: .rounded))
                            .foregroundStyle(pressureColor(m.pressure))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .glassCapsule(tint: pressureColor(m.pressure).opacity(0.3))
                    }
                }
                StackedBar(segments: [
                    .init(value: Double(m.app), color: Palette.memory),
                    .init(value: Double(m.wired), color: Palette.danger.opacity(0.8)),
                    .init(value: Double(m.compressed), color: Palette.warn),
                    .init(value: Double(m.cached), color: Palette.cpu.opacity(0.6)),
                    .init(value: Double(m.free), color: Color.secondary.opacity(0.25)),
                ])
                VStack(spacing: 6) {
                    LegendDot(color: Palette.memory, label: T("ذاكرة التطبيقات", "App memory"), value: Fmt.bytes(m.app))
                    LegendDot(color: Palette.danger.opacity(0.8), label: T("ذاكرة مثبتة (النظام)", "Wired (system)"), value: Fmt.bytes(m.wired))
                    LegendDot(color: Palette.warn, label: T("مضغوطة", "Compressed"), value: Fmt.bytes(m.compressed))
                    LegendDot(color: Palette.cpu.opacity(0.6), label: T("ملفات مخزنة مؤقتاً", "Cached files"), value: Fmt.bytes(m.cached))
                    LegendDot(color: .secondary.opacity(0.4), label: T("حرة", "Free"), value: Fmt.bytes(m.free))
                    LegendDot(color: .clear, label: T("التبديل (Swap)", "Swap used"), value: "\(Fmt.bytes(m.swapUsed)) / \(Fmt.bytes(m.swapTotal))")
                }
                Footnote(text: T("الذاكرة المخزنة مؤقتاً تُحرَّر تلقائياً عند الحاجة. المؤشر الحقيقي هو «ضغط الذاكرة» واستخدام Swap.",
                                 "Cached memory is released automatically when needed. The real signal is memory pressure and swap use."))
            }

            Card(title: T("أكثر التطبيقات استخداماً للذاكرة", "Top memory users"), symbol: "memorychip.fill", tint: Palette.memory) {
                let apps = s.apps.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(15)
                let maxM = Double(apps.first?.memoryBytes ?? 1)
                ForEach(Array(apps)) { a in
                    RankedRow(iconPath: a.bundlePath, isSystem: a.isSystem, name: a.name, value: Fmt.bytes(a.memoryBytes),
                              secondary: a.processes.count > 1 ? T("\(a.processes.count) عمليات", "\(a.processes.count) procs") : nil,
                              fraction: Double(a.memoryBytes) / maxM, tint: Palette.memory, expandable: true) {
                        ProcessList(processes: a.processes.sorted { $0.memoryBytes > $1.memoryBytes })
                    }
                }
            }
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p { case .normal: Palette.battery; case .warning: Palette.warn; case .critical: Palette.danger }
    }
}
