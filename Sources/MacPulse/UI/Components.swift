import SwiftUI
import AppKit

// MARK: - Palette

enum Palette {
    static let cpu = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let memory = Color(red: 0.69, green: 0.45, blue: 1.0)
    static let power = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let battery = Color(red: 0.25, green: 0.8, blue: 0.45)
    static let down = Color(red: 0.2, green: 0.72, blue: 0.95)
    static let up = Color(red: 1.0, green: 0.42, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.75, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.33)

    static func level(_ f: Double) -> Color { f > 0.85 ? danger : f > 0.65 ? warn : battery }
}

// MARK: - Liquid Glass (macOS 26+) with a material fallback for macOS 14–15

enum Radius {
    static let card: CGFloat = 20     // concentric with the popover's rounded corners
    static let tile: CGFloat = 18
    static let inner: CGFloat = 12
}

extension View {
    /// Glass surface for a content group. Optional tint gives each metric a faint colour identity.
    @ViewBuilder
    func glassCard(_ radius: CGFloat = Radius.card, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.14)) } ?? .regular,
                             in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Interactive glass capsule for chips and small controls.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect((tint.map { Glass.regular.tint($0) } ?? .regular).interactive(interactive), in: Capsule())
        } else {
            self.background(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
    }

    /// System glass button style where available.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Groups glass shapes so they blend/morph together (no-op before macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var trailing: String?
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint ?? .secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill((tint ?? .secondary).opacity(0.16)))
                    }
                    Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: tint)
    }
}

// MARK: - Stat tile with sparkline

struct StatTile: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var series: [Double] = []
    var series2: [Double]? = nil
    var tint2: Color = .clear

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            Sparkline(values: series, tint: tint, values2: series2, tint2: tint2).frame(height: 30)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(Radius.tile, tint: tint)
    }
}

/// Live sparkline rasterised on the CPU with Core Graphics into a small bitmap (≈45 KB) and shown
/// as an image. Measured: both Swift Charts and SwiftUI `Canvas` make the GPU renderer allocate
/// ~185 MB of transient "owned unmapped (graphics)" memory on every redraw; a plain image does not.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var values2: [Double]? = nil
    var tint2: Color = .clear
    var fill = true
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { g in
            if let img = SparklineRenderer.render(values: values, values2: values2, tint: NSColor(tint), tint2: NSColor(tint2),
                                                  fill: fill, size: g.size, scale: scale) {
                Image(decorative: img, scale: scale)
            }
        }
    }
}

enum SparklineRenderer {
    static func render(values: [Double], values2: [Double]?, tint: NSColor, tint2: NSColor,
                       fill: Bool, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 2, h > 2, values.count > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        let W = CGFloat(w), H = CGFloat(h)
        let maxV = max(values.max() ?? 0, values2?.max() ?? 0, 0.0001)
        let pad = scale
        func points(_ vs: [Double]) -> [CGPoint] {
            let dx = W / CGFloat(vs.count - 1)
            // CG origin is bottom-left.
            return vs.enumerated().map { CGPoint(x: CGFloat($0.offset) * dx, y: pad + CGFloat(max(0, $0.element) / maxV) * (H - 2 * pad)) }
        }
        func curve(_ pts: [CGPoint]) -> CGMutablePath {
            let p = CGMutablePath()
            p.move(to: pts[0])
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                p.addQuadCurve(to: mid, control: pts[i - 1])
            }
            p.addLine(to: pts[pts.count - 1])
            return p
        }
        let pts = points(values)
        let line = curve(pts)
        if fill {
            let area = line.mutableCopy()!
            area.addLine(to: CGPoint(x: W, y: 0)); area.addLine(to: CGPoint(x: 0, y: 0)); area.closeSubpath()
            ctx.saveGState()
            ctx.addPath(area); ctx.clip()
            let c = tint.usingColorSpace(.sRGB) ?? tint
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: [c.withAlphaComponent(0.35).cgColor, c.withAlphaComponent(0.02).cgColor] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: .zero, options: [])
            }
            ctx.restoreGState()
        }
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        ctx.addPath(line); ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(1.5 * scale); ctx.strokePath()
        if let v2 = values2, v2.count > 1 {
            ctx.addPath(curve(points(v2))); ctx.setStrokeColor(tint2.cgColor); ctx.setLineWidth(1.2 * scale); ctx.strokePath()
        }
        return ctx.makeImage()
    }
}

// MARK: - Meter bar

struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct StackedBar: View {
    struct Segment: Identifiable { let id = UUID(); let value: Double; let color: Color }
    let segments: [Segment]
    var height: CGFloat = 14

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    Capsule().fill(s.color).frame(width: max(0, g.size.width * s.value / total - 2))
                }
            }
        }
        .frame(height: height)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: - App icon (cached NSWorkspace icons)

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        if let i = cache[path] { return i }
        // Workspace icons carry 1024 px representations (~4 MB each once decoded). Keep only a
        // 64 px bitmap so dozens of rows cost a few KB each.
        let full = NSWorkspace.shared.icon(forFile: path)
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.addRepresentation(rep)
        if cache.count > 200 { cache.removeAll() }
        cache[path] = img
        return img
    }
}

struct AppIconView: View {
    let path: String?
    var isSystem = false
    var size: CGFloat = 20
    var body: some View {
        Group {
            if let img = IconCache.icon(for: path) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: isSystem ? "gearshape.2.fill" : "terminal.fill")
                    .resizable().scaledToFit().padding(3)
                    .foregroundStyle(.secondary)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            }
        }
        .frame(width: size, height: size)
    }
}

/// One row in a ranked list: icon, name, value, proportional bar. Expandable for process details.
struct RankedRow<Detail: View>: View {
    let iconPath: String?
    let isSystem: Bool
    let name: String
    let value: String
    var secondary: String? = nil
    let fraction: Double
    let tint: Color
    var expandable = false
    @ViewBuilder var detail: Detail
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppIconView(path: iconPath, isSystem: isSystem, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let secondary { Text(secondary).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        Text(value).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                    }
                    Meter(fraction: fraction, tint: tint, height: 4)
                }
                if expandable {
                    Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if expandable { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } }
            if expanded {
                detail.padding(.leading, 32).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

extension RankedRow where Detail == EmptyView {
    init(iconPath: String?, isSystem: Bool, name: String, value: String, secondary: String? = nil, fraction: Double, tint: Color) {
        self.init(iconPath: iconPath, isSystem: isSystem, name: name, value: value, secondary: secondary,
                  fraction: fraction, tint: tint, expandable: false) { EmptyView() }
    }
}

struct ProcessList: View {
    let processes: [ProcessUsage]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(processes.prefix(12)) { p in
                HStack(spacing: 8) {
                    Text(p.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text("\(p.pid)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Group {
                        Text(String(format: "%.1f%%", p.cpuPercent))
                        Text(Fmt.watts(p.powerW))
                        Text(Fmt.bytes(p.memoryBytes))
                        if p.netInRate + p.netOutRate > 0 { Text(Fmt.rate(p.netInRate + p.netOutRate)) }
                    }
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if processes.count > 12 {
                Text(T("+ \(processes.count - 12) عملية أخرى", "+ \(processes.count - 12) more processes"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var tint: Color? = nil
    var body: some View {
        HStack {
            Text(key).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.callout, design: .rounded, weight: .medium)).monospacedDigit().foregroundStyle(tint ?? .primary)
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

/// Small footnote text used under cards.
struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
