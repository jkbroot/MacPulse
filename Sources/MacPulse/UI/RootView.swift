import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview, battery, network, memory, reports, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: T("عام", "Overview")
        case .battery: T("الطاقة", "Energy")
        case .network: T("الشبكة", "Network")
        case .memory: T("الذاكرة", "Memory")
        case .reports: T("التقارير", "Reports")
        case .settings: T("الإعدادات", "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .battery: "bolt.fill"
        case .network: "network"
        case .memory: "memorychip.fill"
        case .reports: "chart.bar.xaxis"
        case .settings: "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var monitor: Monitor
    @AppStorage("selectedTab") private var tabRaw = Tab.overview.rawValue
    @Namespace private var glassNS
    private var tab: Tab { Tab(rawValue: tabRaw) ?? .overview }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            if RootView.renderMode {
                content.padding(.horizontal, 14).padding(.vertical, 10).frame(width: 460)
            } else {
                ScrollView { content.padding(.horizontal, 14).padding(.vertical, 10) }
                    .scrollIndicators(.never)
            }
        }
        .frame(width: 460, height: RootView.renderMode ? nil : 640)
        // Rebuild everything when the language changes so every T("…","…") is re-evaluated.
        .id(monitor.language)
        .environment(\.layoutDirection, L10n.layoutDirection)
        .environment(\.locale, L10n.locale)
    }

    static var renderMode = false

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: OverviewView()
        case .battery: BatteryView()
        case .network: NetworkView()
        case .memory: MemoryView()
        case .reports: ReportsView()
        case .settings: SettingsView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.battery)
                .frame(width: 34, height: 34)
                .glassCapsule(tint: Palette.battery.opacity(0.25))
            VStack(alignment: .leading, spacing: 0) {
                Text("MacPulse").font(.system(.headline, design: .rounded))
                Text(T("مراقب أداء الجهاز", "System monitor")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            let s = monitor.snapshot.selfUsage
            HStack(spacing: 5) {
                Image(systemName: "leaf.fill").foregroundStyle(Palette.battery)
                Text("\(String(format: "%.1f%%", s.cpuPercent)) · \(Fmt.bytes(s.memoryBytes))").monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassCapsule()
            .help(T("استهلاك MacPulse نفسه", "MacPulse's own usage"))
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    /// Liquid Glass tab bar: the selected tab carries a tinted glass capsule that morphs between tabs.
    private var tabBar: some View {
        GlassGroup(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { t in
                    let selected = tab == t
                    Button {
                        withAnimation(.bouncy(duration: 0.35)) { tabRaw = t.rawValue }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold))
                            Text(t.title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .contentShape(Capsule())
                        .modifier(SelectedGlass(selected: selected, ns: glassNS))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glassCapsule()
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }
}

private struct SelectedGlass: ViewModifier {
    let selected: Bool
    let ns: Namespace.ID
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if selected {
                content
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.35)).interactive(), in: Capsule())
                    .glassEffectID("selection", in: ns)
            } else {
                content
            }
        } else {
            content.background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        }
    }
}
