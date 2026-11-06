import Foundation
import IOKit
import IOKit.ps

/// Reads the smart-battery controller directly from the IORegistry (AppleSmartBattery).
/// Individual keys are fetched instead of the whole property table to keep each read cheap.
final class BatteryCollector {
    private var service: io_service_t = 0
    private var runLoopSource: CFRunLoopSource?

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
    }

    /// Calls `handler` on the main run loop when the power source changes (plug / unplug / % step).
    func observeChanges(_ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<HandlerBox>.fromOpaque(ctx).takeUnretainedValue().fn()
        }, box)?.takeRetainedValue() else { return }
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private final class HandlerBox { let fn: () -> Void; init(_ f: @escaping () -> Void) { fn = f } }

    private func prop(_ key: String) -> Any? {
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func int(_ key: String) -> Int? { (prop(key) as? NSNumber)?.intValue }
    private func int64(_ any: Any?) -> Int64? { (any as? NSNumber)?.int64Value }
    private func bool(_ key: String) -> Bool { (prop(key) as? NSNumber)?.boolValue ?? false }

    func read() -> BatteryInfo {
        var b = BatteryInfo()
        guard service != 0, let current = int("CurrentCapacity") else { return b }
        b.present = true
        let maxCap = max(int("MaxCapacity") ?? 100, 1)
        b.percent = Double(current) / Double(maxCap)
        b.isCharging = bool("IsCharging")
        b.externalConnected = bool("ExternalConnected")
        b.fullyCharged = bool("FullyCharged")
        b.cycleCount = int("CycleCount") ?? 0
        b.voltageV = Double(int("Voltage") ?? 0) / 1000
        // Amperage is a signed value stored in an unsigned 64-bit slot: reinterpret the bits.
        b.amperageA = Double(int64(prop("InstantAmperage")) ?? int64(prop("Amperage")) ?? 0) / 1000

        if let t = int("TimeRemaining"), t > 0, t < 65535 { b.timeRemainingMin = t }

        if let data = prop("BatteryData") as? [String: Any] {
            b.designCapacity = (data["DesignCapacity"] as? NSNumber)?.intValue ?? 0
            b.fullChargeCapacity = (data["FullChargeCapacity"] as? NSNumber)?.intValue ?? 0
            b.currentCapacity = (data["RemainingCapacity"] as? NSNumber)?.intValue ?? 0
            if let t = (data["Temperature"] as? NSNumber)?.doubleValue, t > 0 { b.temperatureC = t / 100 }
        }
        if b.designCapacity == 0 { b.designCapacity = int("DesignCapacity") ?? 0 }
        if b.fullChargeCapacity == 0 { b.fullChargeCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? 0 }
        if b.currentCapacity == 0 { b.currentCapacity = int("AppleRawCurrentCapacity") ?? 0 }
        if b.temperatureC == nil, let t = int("Temperature"), t > 0 { b.temperatureC = Double(t) / 100 }
        if b.temperatureC == nil, let t = int("VirtualTemperature"), t > 0 { b.temperatureC = Double(t) / 100 }

        if let tel = prop("PowerTelemetryData") as? [String: Any],
           let load = (tel["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            b.systemPowerW = load / 1000
        } else if !b.externalConnected, b.amperageA < 0 {
            b.systemPowerW = -b.batteryPowerW
        }
        if let ad = prop("AdapterDetails") as? [String: Any], b.externalConnected {
            b.adapterWatts = (ad["Watts"] as? NSNumber)?.intValue
        }
        return b
    }
}
