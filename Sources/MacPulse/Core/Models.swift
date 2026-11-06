import Foundation

// MARK: - Snapshot models (value types, safe to hand from the sampler queue to the main thread)

struct ProcessUsage: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    var cpuPercent: Double          // % of one core
    var powerW: Double              // from kernel energy counters
    var memoryBytes: UInt64         // phys_footprint (what Activity Monitor shows)
    var wakeupsPerSec: Double
    var netInRate: Double           // bytes/s
    var netOutRate: Double
}

struct AppUsage: Identifiable, Hashable {
    let id: String                  // stable key: bundle path or "proc:<name>"
    let name: String
    let bundlePath: String?
    let isSystem: Bool
    var cpuPercent: Double = 0
    var powerW: Double = 0
    var memoryBytes: UInt64 = 0
    var wakeupsPerSec: Double = 0
    var netInRate: Double = 0
    var netOutRate: Double = 0
    var processes: [ProcessUsage] = []

    var netTotalRate: Double { netInRate + netOutRate }
}

struct DestinationUsage: Identifiable, Hashable {
    var id: String { appID + "|" + address }
    let appID: String
    let appName: String
    let address: String
    var host: String?
    var proto: String
    var inRate: Double
    var outRate: Double
    var total: Double { inRate + outRate }
}

struct InterfaceUsage: Identifiable, Hashable {
    var id: String { bsdName }
    let bsdName: String
    let displayName: String
    var inRate: Double
    var outRate: Double
    var totalIn: UInt64
    var totalOut: UInt64
}

struct BatteryInfo: Hashable {
    var present = false
    var percent: Double = 0
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var timeRemainingMin: Int?      // nil while macOS is still calculating
    var voltageV: Double = 0
    var amperageA: Double = 0       // + charging, − discharging
    var batteryPowerW: Double { voltageV * amperageA }
    var systemPowerW: Double?       // whole-machine draw (PowerTelemetry SystemLoad)
    var adapterWatts: Int?
    var cycleCount: Int = 0
    var designCapacity: Int = 0     // mAh
    var fullChargeCapacity: Int = 0 // mAh
    var currentCapacity: Int = 0    // mAh
    var temperatureC: Double?
    var health: Double { designCapacity > 0 ? Double(fullChargeCapacity) / Double(designCapacity) : 0 }
}

struct MemoryInfo: Hashable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryPressure: Int, Hashable {
    case normal = 1, warning = 2, critical = 4
    var label: String {
        switch self { case .normal: T("طبيعي", "Normal"); case .warning: T("مرتفع", "Elevated"); case .critical: T("حرج", "Critical") }
    }
}

struct CPUInfo: Hashable {
    var usage: Double = 0           // 0...1 of whole machine
    var user: Double = 0
    var system: Double = 0
    var cores: Int = ProcessInfo.processInfo.activeProcessorCount
    var load1: Double = 0
}

struct SelfUsage: Hashable {
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
}

struct Snapshot {
    var date = Date()
    var cpu = CPUInfo()
    var memory = MemoryInfo()
    var battery = BatteryInfo()
    var apps: [AppUsage] = []
    var destinations: [DestinationUsage] = []
    var interfaces: [InterfaceUsage] = []
    var netInRate: Double = 0
    var netOutRate: Double = 0
    var attributedNetRate: Double = 0
    var appsPowerW: Double = 0
    var unreadableProcesses = 0
    var selfUsage = SelfUsage()
}

/// Small rolling series kept in memory for the live sparklines.
struct LivePoint: Identifiable, Hashable {
    var id: Date { t }
    let t: Date
    let cpu: Double
    let mem: Double
    let power: Double
    let netIn: Double
    let netOut: Double
}
