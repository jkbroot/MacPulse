import AppKit
import SwiftUI

/// A menu-bar agent (LSUIElement): no Dock icon, no main window. The status item's title is drawn
/// by AppKit directly, and SwiftUI only exists while the popover is on screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor.shared
    private var lastSymbol = ""
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        monitor.onMenuBarChange = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        monitor.start()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.sampler.resetClock() }
        }

        // SIGTERM (logout, `kill`, launchd) → orderly shutdown so history is flushed and nettop stopped.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        termSource = src

        if let dir = ProcessInfo.processInfo.environment["MACPULSE_RENDER"] { renderPreviews(to: dir) }
        // Diagnostics: MACPULSE_OPEN=<tab> opens the real popover on that tab (for CPU/energy measurement).
        if let tab = ProcessInfo.processInfo.environment["MACPULSE_OPEN"] {
            UserDefaults.standard.set(tab, forKey: "selectedTab")
            popover.behavior = .applicationDefined   // stay open while measuring
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                if let b = statusItem.button { togglePopover(b) }
            }
        }
        if ProcessInfo.processInfo.environment["MACPULSE_REPORTCHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [self] in
                monitor.sampler.query({ store in ReportRange.allCases.map { ($0, ReportData.load(store: store, range: $0)) } }) { results in
                    for (r, d) in results {
                        print("REPORT \(r.rawValue): series=\(d.series.count) apps=\(d.apps.count) dests=\(d.dests.count) avgW=\(d.avgPowerW.map { String(format: "%.1f", $0) } ?? "nil") drain=\(d.drainPerHour.map { String(format: "%.1f", $0) } ?? "nil") in=\(Fmt.bytes(d.totalIn)) top=\(d.apps.prefix(3).map(\.name))")
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Diagnostics: `MACPULSE_RENDER=/some/dir MacPulse` renders every tab to PNG with live data, then quits.
    private func renderPreviews(to dir: String) {
        RootView.renderMode = true
        // Menu bar label with every item, drawn by the same code as the real status item.
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [self] in
            let title = Self.title(for: monitor.menuBarSegments([.power, .cpu, .memory, .netDown, .netUp, .battery]), leadingGap: true)
            for (name, appearance) in [("menubar-dark", NSAppearance.Name.darkAqua), ("menubar-light", .aqua)] {
                let size = NSSize(width: ceil(title.size().width) + 44, height: 24)
                let img = NSImage(size: size)
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    img.lockFocus()
                    (appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: size).fill()
                    let icon = NSImage(systemSymbolName: monitor.menuBarSymbol, accessibilityDescription: nil)!
                        .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
                    let tinted = NSImage(size: icon.size, flipped: false) { r in icon.draw(in: r); NSColor.labelColor.set(); r.fill(using: .sourceAtop); return true }
                    tinted.draw(at: NSPoint(x: 8, y: (size.height - icon.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                    let m = NSMutableAttributedString(attributedString: title)
                    m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: m.length))
                    m.draw(at: NSPoint(x: 8 + icon.size.width, y: (size.height - title.size().height) / 2))
                    img.unlockFocus()
                }
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [self] in
            monitor.panelDidOpen()
            var i = 0
            func next() {
                guard i < Tab.allCases.count else { NSApp.terminate(nil); return }
                let tab = Tab.allCases[i]; i += 1
                UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
                let view = RootView().environmentObject(monitor)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark)
                // Let async loads (reports) settle, then render.
                let holder = NSHostingView(rootView: view)
                holder.frame = NSRect(x: 0, y: 0, width: 460, height: 620)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let r = ImageRenderer(content: RootView().environmentObject(self.monitor)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tab.rawValue).png"))
                    }
                    _ = holder
                    next()
                }
            }
            next()
        }
    }

    private var termSource: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        monitor.sampler.shutdown()
    }

    private var lastSegments: [MenuBarSegment]?
    private var lastShowIcon: Bool?

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let segments = monitor.menuBarSegments()
        // Never leave an empty, unclickable status item.
        let showIcon = monitor.showMenuBarIcon || segments.isEmpty
        let symbol = monitor.menuBarSymbol
        if symbol != lastSymbol || showIcon != lastShowIcon {
            lastSymbol = symbol
            lastShowIcon = showIcon
            if showIcon {
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacPulse")
                img?.isTemplate = true
                button.image = img?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            } else {
                button.image = nil
            }
            button.imagePosition = showIcon ? .imageLeading : .noImage
        }
        guard segments != lastSegments else { return }
        lastSegments = segments
        button.attributedTitle = Self.title(for: segments, leadingGap: showIcon)
    }

    /// "⚡︎ 12W   ⌁ 8%   🇸🇦 1.2.3.4" — SF Symbols as text attachments, digits monospaced so the item
    /// doesn't jitter in width as numbers change.
    static func title(for segments: [MenuBarSegment], leadingGap: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let out = NSMutableAttributedString()
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
        for (i, seg) in segments.enumerated() {
            if i > 0 || leadingGap { out.append(NSAttributedString(string: i > 0 ? "   " : " ", attributes: textAttrs)) }
            if let sym = seg.symbol, let att = symbolAttachment(sym, font: font) {
                out.append(att)
                out.append(NSAttributedString(string: "\u{2009}", attributes: textAttrs))
            }
            out.append(NSAttributedString(string: seg.text, attributes: textAttrs))
        }
        return out
    }

    private static var symbolCache: [String: NSAttributedString] = [:]

    /// The image draws lazily, so `labelColor` resolves against the menu bar's *current* appearance
    /// (light/dark wallpaper, highlighted state) at draw time — no appearance observers needed.
    private static func symbolAttachment(_ name: String, font: NSFont) -> NSAttributedString? {
        if let c = symbolCache[name] { return c }
        let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        let str = NSAttributedString(attachment: att)
        symbolCache[name] = str
        return str
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let host = NSHostingController(rootView: RootView().environmentObject(monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidShow(_ notification: Notification) { monitor.panelDidOpen() }

    func popoverDidClose(_ notification: Notification) {
        monitor.panelDidClose()
        // Drop the SwiftUI hierarchy entirely while hidden: zero view updates, less memory.
        popover.contentViewController = nil
    }
}
