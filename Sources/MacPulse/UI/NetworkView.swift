import SwiftUI

struct NetworkView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let s = monitor.snapshot
        VStack(spacing: 12) {
            Card(tint: Palette.down) {
                HStack {
                    rateBlock(T("تنزيل", "Download"), s.netInRate, "arrow.down", Palette.down)
                    Divider().frame(height: 40)
                    rateBlock(T("رفع", "Upload"), s.netOutRate, "arrow.up", Palette.up)
                }
                ZStack(alignment: .topTrailing) {
                    Sparkline(values: monitor.live.map(\.netIn), tint: Palette.down,
                              values2: monitor.live.map(\.netOut), tint2: Palette.up)
                    Text(T("أعلى: ", "Peak: ") + Fmt.rate(monitor.live.map { max($0.netIn, $0.netOut) }.max() ?? 0))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                .frame(height: 80)
                Footnote(text: T("آخر 15 دقيقة", "Last 15 minutes"))
            }

            identityCard

            Card(title: T("الواجهات", "Interfaces"), symbol: "antenna.radiowaves.left.and.right", tint: Palette.cpu) {
                let ifs = s.interfaces.filter {
                    InterfaceCollector.isPhysical($0.bsdName) ? $0.totalIn + $0.totalOut > 0 : $0.inRate + $0.outRate > 0
                }.prefix(6)
                ForEach(Array(ifs)) { i in
                    HStack(spacing: 10) {
                        Image(systemName: icon(i.bsdName)).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.displayName).font(.callout)
                            Text(T("الإجمالي", "Total") + " " + Fmt.updown(Fmt.bytes(i.totalIn), Fmt.bytes(i.totalOut)))
                                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Spacer()
                        Text(Fmt.updown(Fmt.rate(i.inRate), Fmt.rate(i.outRate))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Card(title: T("التطبيقات", "Apps"), symbol: "app.connected.to.app.below.fill", tint: Palette.down) {
                let apps = s.apps.filter { $0.netTotalRate > 0 }.sorted { $0.netTotalRate > $1.netTotalRate }.prefix(15)
                let maxR = apps.first?.netTotalRate ?? 1
                if apps.isEmpty { EmptyHint(text: T("لا توجد حركة شبكة ملحوظة حالياً", "No notable network activity right now")) }
                ForEach(Array(apps)) { a in
                    RankedRow(iconPath: a.bundlePath, isSystem: a.isSystem, name: a.name, value: Fmt.rate(a.netTotalRate),
                              secondary: Fmt.updown(Fmt.rate(a.netInRate, compact: true), Fmt.rate(a.netOutRate, compact: true)),
                              fraction: a.netTotalRate / maxR, tint: Palette.down, expandable: true) {
                        DestinationList(dests: s.destinations.filter { $0.appID == a.id }, showApp: false)
                    }
                }
                let unattributed = max(0, s.netInRate + s.netOutRate - s.attributedNetRate)
                if unattributed > 1024 {
                    Footnote(text: T("غير منسوب: \(Fmt.rate(unattributed)) — اتصالات قصيرة جداً، أو حركة النظام/VPN.",
                                     "Unattributed: \(Fmt.rate(unattributed)) — very short connections, or system/VPN traffic."))
                }
            }

            Card(title: T("إلى أين تذهب البيانات؟", "Where is the data going?"), symbol: "globe", tint: Palette.up) {
                let d = s.destinations.filter { $0.address != "*" }.prefix(12)
                if d.isEmpty { EmptyHint(text: T("لا توجد وجهات نشطة", "No active destinations")) }
                DestinationList(dests: Array(d), showApp: true)
            }
        }
    }

    /// Local and (opt-in) public address with country.
    private var identityCard: some View {
        Card(title: T("عنوان الجهاز", "This Mac's address"), symbol: "location.fill", tint: Palette.battery) {
            KeyValueRow(key: T("IP المحلي", "Local IP"),
                        value: monitor.localIP.map { "\($0.ip)  (\($0.interface))" } ?? "—")
            if monitor.publicIPEnabled {
                if let p = monitor.publicIP {
                    KeyValueRow(key: T("IP العام", "Public IP"), value: p.ip)
                    if let cc = p.countryCode {
                        KeyValueRow(key: T("الدولة", "Country"), value: flagEmoji(cc) + " " + L10n.countryName(cc))
                    }
                    if let org = p.org { KeyValueRow(key: T("مزود الخدمة", "Provider"), value: org) }
                } else {
                    HStack { ProgressView().controlSize(.small); Text(T("جاري التحقق…", "Checking…")).font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Footnote(text: T("يتم الاستعلام من ipinfo.io عند تغيّر الشبكة أو كل 30 دقيقة.",
                                     "Looked up via ipinfo.io when the network changes or every 30 min."))
                    Spacer()
                    Button { monitor.publicIPService.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                        .glassButton().controlSize(.small)
                }
            } else {
                HStack {
                    Footnote(text: T("معرفة الـ IP العام والدولة تتطلب الاتصال بخدمة خارجية (ipinfo.io).",
                                     "Showing your public IP and country requires contacting an external service (ipinfo.io)."))
                    Spacer()
                    Button(T("إظهار", "Show")) { monitor.publicIPEnabled = true }.glassButton(prominent: true).controlSize(.small)
                }
            }
        }
    }

    private func rateBlock(_ title: String, _ v: Double, _ sym: String, _ c: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sym).font(.system(size: 14, weight: .bold)).foregroundStyle(c)
                .frame(width: 34, height: 34).glassCapsule(tint: c.opacity(0.3))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.rate(v)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(_ n: String) -> String {
        if n.hasPrefix("utun") || n.hasPrefix("ipsec") { return "lock.shield" }
        if n.hasPrefix("awdl") || n.hasPrefix("llw") { return "dot.radiowaves.left.and.right" }
        if n == "en0" { return "wifi" }
        return "cable.connector"
    }
}

struct DestinationList: View {
    let dests: [DestinationUsage]
    let showApp: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dests.isEmpty { Text(T("لا توجد اتصالات نشطة", "No active connections")).font(.caption2).foregroundStyle(.tertiary) }
            ForEach(dests.prefix(10)) { d in
                HStack(spacing: 8) {
                    Text(d.proto).font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.primary.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label(d)).font(.caption).lineLimit(1).truncationMode(.middle)
                        if showApp || d.host != nil {
                            Text(showApp ? "\(d.appName) · \(d.address)" : d.address)
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(Fmt.updown(Fmt.rate(d.inRate, compact: true), Fmt.rate(d.outRate, compact: true)))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ d: DestinationUsage) -> String {
        if d.address == "*" { return T("بث محلي / Multicast", "Local broadcast / multicast") }
        if let h = d.host { return h }
        if HostResolver.isPrivate(d.address) { return d.address + T(" (شبكة محلية)", " (local network)") }
        return d.address
    }
}
