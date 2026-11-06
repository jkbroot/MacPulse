import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var dbSize: UInt64 = 0
    @State private var confirmClear = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            Card(title: T("اللغة", "Language"), symbol: "globe", tint: Palette.cpu) {
                Picker(T("لغة الواجهة", "Interface language"), selection: $monitor.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Card(title: T("التشغيل", "Startup"), symbol: "power", tint: Palette.battery) {
                Toggle(isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("الفتح تلقائياً عند تشغيل الجهاز", "Open at login"))
                        Text(T("يعمل في الخلفية كخدمة في شريط القوائم", "Runs in the background from the menu bar"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                if let e = monitor.launchAtLoginError {
                    HStack {
                        Text(e).font(.caption2).foregroundStyle(Palette.warn)
                        Spacer()
                        Button(T("فتح الإعدادات", "Open Settings")) { SMOpenLoginItems.open() }.glassButton().controlSize(.small)
                    }
                }
            }

            menuBarCard

            Card(title: T("الخصوصية", "Privacy"), symbol: "hand.raised.fill", tint: Palette.up) {
                Toggle(isOn: $monitor.resolveHostnames) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("إظهار أسماء الخوادم", "Show server names"))
                        Text(T("استعلام DNS عكسي لعناوين IP", "Reverse-DNS lookup of remote IPs")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $monitor.publicIPEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("معرفة الـ IP العام والدولة", "Look up public IP & country"))
                        Text(T("يتصل بـ ipinfo.io عند تغيّر الشبكة فقط", "Contacts ipinfo.io only when the network changes"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Footnote(text: T("عند إيقاف الخيارين لا يُرسل التطبيق أي شيء خارج جهازك.",
                                 "With both off, the app sends nothing off your Mac."))
            }

            MCPSettingsCard()

            Card(title: T("الأداء والطاقة", "Performance"), symbol: "leaf.fill", tint: Palette.battery) {
                Picker(T("تحديث في الخلفية كل", "Background refresh every"), selection: $monitor.backgroundInterval) {
                    Text(T("5 ثوانٍ", "5 seconds")).tag(5.0)
                    Text(T("10 ثوانٍ (موصى به)", "10 seconds (recommended)")).tag(10.0)
                    Text(T("30 ثانية", "30 seconds")).tag(30.0)
                    Text(T("دقيقة", "1 minute")).tag(60.0)
                }
                Footnote(text: T("عند فتح اللوحة يتم التحديث كل ثانيتين، وعند إغلاقها يعود للفاصل المحدد لتوفير الطاقة. يتم حفظ السجل مرة كل دقيقة.",
                                 "While this panel is open it refreshes every 2 s; when closed it falls back to the interval above to save energy. History is saved once a minute."))
                let s = monitor.snapshot.selfUsage
                KeyValueRow(key: T("استهلاك MacPulse الآن", "MacPulse right now"),
                            value: "\(String(format: "%.2f%%", s.cpuPercent)) CPU · \(Fmt.bytes(s.memoryBytes))")
            }

            Card(title: T("البيانات", "Data"), symbol: "externaldrive.fill", tint: Palette.memory) {
                KeyValueRow(key: T("حجم السجل", "History size"), value: Fmt.bytes(dbSize))
                Footnote(text: T("الدقائق: 30 يوماً · التطبيقات: 180 يوماً · الوجهات: 90 يوماً — كل البيانات محلية على جهازك فقط.",
                                 "Minutes: 30 days · apps: 180 days · destinations: 90 days — all data stays on this Mac."))
                HStack {
                    Button(T("إظهار في Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([monitor.sampler.store.url])
                    }
                    .glassButton()
                    Spacer()
                    Button(T("مسح السجل", "Clear history"), role: .destructive) { confirmClear = true }.glassButton()
                }
                .controlSize(.small)
                if confirmClear {
                    HStack {
                        Text(T("سيتم حذف كل السجل نهائياً.", "All history will be permanently deleted."))
                            .font(.caption).foregroundStyle(Palette.danger)
                        Spacer()
                        Button(T("تأكيد الحذف", "Delete"), role: .destructive) {
                            monitor.sampler.query({ $0.clearAll(); return $0.fileSize() }) { dbSize = $0; confirmClear = false }
                        }
                        .glassButton(prominent: true)
                        Button(T("إلغاء", "Cancel")) { confirmClear = false }.glassButton()
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Text("MacPulse 1.1").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label(T("إنهاء", "Quit"), systemImage: "xmark.circle") }
                    .glassButton().controlSize(.small)
            }
        }
        .onAppear {
            monitor.refreshLaunchAtLogin()
            monitor.sampler.query({ $0.fileSize() }) { dbSize = $0 }
        }
    }

    /// Multi-select: any combination of items, in a fixed, readable order.
    private var menuBarCard: some View {
        Card(title: T("شريط القوائم", "Menu bar"), symbol: "menubar.rectangle", tint: Palette.power) {
            Toggle(T("إظهار أيقونة التطبيق", "Show app icon"), isOn: $monitor.showMenuBarIcon).toggleStyle(.switch)
            Text(T("العناصر المعروضة (اختر أي عدد):", "Items to show (pick any):"))
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(MenuBarItem.allCases) { item in
                    let on = monitor.menuBarItems.contains(item)
                    Button {
                        withAnimation(.snappy) { toggle(item) }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16)
                            Text(item.label).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassCapsule(tint: on ? Color.accentColor.opacity(0.25) : nil, interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            if monitor.menuBarItems.contains(.publicIP) {
                Footnote(text: T("الـ IP العام يتطلب الاتصال بـ ipinfo.io.", "Public IP requires contacting ipinfo.io."))
            }
        }
    }

    private func toggle(_ item: MenuBarItem) {
        var set = Set(monitor.menuBarItems)
        if set.contains(item) { set.remove(item) } else { set.insert(item) }
        monitor.menuBarItems = MenuBarItem.allCases.filter { set.contains($0) }
    }
}

enum SMOpenLoginItems {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
