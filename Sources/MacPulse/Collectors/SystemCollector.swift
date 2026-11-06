import Foundation
import Darwin

/// Whole-machine CPU and memory straight from the Mach host interfaces.
final class SystemCollector {
    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let host = mach_host_self()
    private let pageSize = UInt64(vm_kernel_page_size)
    private let totalMemory = ProcessInfo.processInfo.physicalMemory

    func cpu() -> CPUInfo {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        var result = CPUInfo()
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { result.load1 = loads[0] }
        guard kr == KERN_SUCCESS else { return result }

        let t = info.cpu_ticks
        let now = (user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
        defer { prevTicks = now }
        guard let p = prevTicks else { return result }
        let du = Double(now.user &- p.user + now.nice &- p.nice)
        let ds = Double(now.system &- p.system)
        let di = Double(now.idle &- p.idle)
        let total = du + ds + di
        guard total > 0 else { return result }
        result.user = du / total
        result.system = ds / total
        result.usage = (du + ds) / total
        return result
    }

    func memory() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var m = MemoryInfo()
        m.total = totalMemory
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            m.wired = UInt64(stats.wire_count) * pageSize
            m.compressed = UInt64(stats.compressor_page_count) * pageSize
            m.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
            m.free = UInt64(stats.free_count) * pageSize
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            m.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        return m
    }
}
