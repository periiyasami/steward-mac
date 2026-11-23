import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - CPU

/// Processor ticks summed over every core.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: UInt64 { user + system + nice }
    public var total: UInt64 { busy + idle }

    /// Percent busy between two samples, 0 to 100.
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> Double {
        guard b.total > a.total else { return 0 }
        let busy = Double(b.busy &- a.busy)
        let total = Double(b.total - a.total)
        return min(100, max(0, busy / total * 100))
    }

    /// The current ticks from the kernel.
    public static func read() -> CPUTicks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var t = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            t.user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            t.system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            t.idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            t.nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        return t
    }
}

// MARK: - Memory

public struct MemoryStats: Sendable, Equatable {
    public let total: UInt64
    public let active: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let inactive: UInt64
    public let free: UInt64

    public init(total: UInt64, active: UInt64, wired: UInt64, compressed: UInt64, inactive: UInt64, free: UInt64) {
        self.total = total
        self.active = active
        self.wired = wired
        self.compressed = compressed
        self.inactive = inactive
        self.free = free
    }

    /// Active, wired, and compressed memory: what apps hold right now. Never more than installed memory.
    public var used: UInt64 { min(total, active + wired + compressed) }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    /// Builds the figures from page counts.
    public static func from(pageSize: UInt64, total: UInt64, active: UInt64, wired: UInt64, compressed: UInt64,
                            inactive: UInt64, free: UInt64) -> MemoryStats {
        MemoryStats(total: total, active: active * pageSize, wired: wired * pageSize, compressed: compressed * pageSize,
                    inactive: inactive * pageSize, free: free * pageSize)
    }

    public static func read() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return .from(pageSize: UInt64(pageSize), total: ProcessInfo.processInfo.physicalMemory,
                     active: UInt64(stats.active_count), wired: UInt64(stats.wire_count),
                     compressed: UInt64(stats.compressor_page_count), inactive: UInt64(stats.inactive_count),
                     free: UInt64(stats.free_count))
    }
}

// MARK: - Disk

public struct DiskStats: Sendable, Equatable {
    public let total: Int64
    public let available: Int64
    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }
    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public static func read(at url: URL) -> DiskStats? {
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity else { return nil }
        return DiskStats(total: Int64(total), available: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - Network

/// Bytes in and out over every network interface since startup (loopback excluded).
public struct NetworkCounters: Sendable, Equatable {
    public let received: UInt64
    public let sent: UInt64
    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }

    /// Bytes per second between two samples.
    public static func rate(from a: NetworkCounters, to b: NetworkCounters, seconds: Double) -> (down: Double, up: Double) {
        guard seconds > 0 else { return (0, 0) }
        // Counters can wrap or reset when an interface goes away.
        let down = b.received >= a.received ? Double(b.received - a.received) / seconds : 0
        let up = b.sent >= a.sent ? Double(b.sent - a.sent) / seconds : 0
        return (down, up)
    }

    public static func read() -> NetworkCounters {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return NetworkCounters(received: 0, sent: 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes)
            tx += UInt64(d.ifi_obytes)
        }
        return NetworkCounters(received: rx, sent: tx)
    }
}

// MARK: - Battery

public struct BatteryInfo: Sendable, Equatable {
    public let cycleCount: Int?
    public let designCapacity: Int?
    public let fullChargeCapacity: Int?
    public let chargePercent: Int?
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let condition: String?
    public let temperatureC: Double?

    public init(cycleCount: Int?, designCapacity: Int?, fullChargeCapacity: Int?, chargePercent: Int?,
                isCharging: Bool, isPluggedIn: Bool, condition: String?, temperatureC: Double?) {
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.condition = condition
        self.temperatureC = temperatureC
    }

    /// Full-charge capacity over design capacity, as a percent (can exceed 100 on a new battery).
    public var healthPercent: Int? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Int((Double(full) / Double(design) * 100).rounded())
    }

    /// Reads AppleSmartBattery's properties. Prefers the raw mAh figures on Apple silicon.
    public static func parse(_ p: [String: Any]) -> BatteryInfo {
        // Apple silicon keeps the mAh figures in a nested BatteryData dictionary.
        let nested = p["BatteryData"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { (p[k] as? NSNumber)?.intValue ?? (nested[k] as? NSNumber)?.intValue }
        let full = int("AppleRawMaxCapacity") ?? int("FullChargeCapacity") ?? int("NominalChargeCapacity")
        let current = int("AppleRawCurrentCapacity") ?? int("CurrentCapacity")
        var percent: Int?
        if let c = int("CurrentCapacity"), let m = int("MaxCapacity"), m > 0, m <= 100 {
            percent = c * 100 / m  // MaxCapacity is a percent scale on Apple silicon
        } else if let current, let full, full > 0 {
            percent = current * 100 / full
        }
        let temp = int("Temperature").map { Double($0) / 100 }
        return BatteryInfo(cycleCount: int("CycleCount"), designCapacity: int("DesignCapacity"), fullChargeCapacity: full,
                           chargePercent: percent, isCharging: (p["IsCharging"] as? Bool) ?? false,
                           isPluggedIn: (p["ExternalConnected"] as? Bool) ?? false,
                           condition: p["BatteryHealthCondition"] as? String,
                           temperatureC: temp)
    }

    /// nil on a Mac without a battery.
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        guard (dict["BatteryInstalled"] as? Bool) ?? true else { return nil }
        return parse(dict)
    }
}

// MARK: - Processes

/// A running process of the current user, with its memory and CPU time.
public struct ProcessSample: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let path: String
    /// Resident memory in bytes.
    public let memory: UInt64
    /// User and system CPU time in nanoseconds, since the process started.
    public let cpuTime: UInt64

    public init(pid: Int32, path: String, memory: UInt64, cpuTime: UInt64) {
        self.pid = pid
        self.path = path
        self.memory = memory
        self.cpuTime = cpuTime
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The .app the process belongs to, if any.
    public var appPath: String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    public static func read(pid: Int32) -> ProcessSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        return ProcessSample(pid: pid, path: path, memory: info.pti_resident_size,
                             cpuTime: info.pti_total_user + info.pti_total_system)
    }

    /// Every process this user may read.
    public static func all() -> [ProcessSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.prefix(Int(max(0, filled))).filter { $0 > 0 }.compactMap { read(pid: $0) }
    }
}

public enum Uptime {
    /// Seconds since the Mac started.
    public static func seconds() -> TimeInterval {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(boottime.tv_sec)
    }
}

/// Decides when to warn about low disk space: once when space drops under the
/// limit, and again only after it has gone back above the limit plus a margin.
public struct LowSpaceAlert: Sendable {
    public var limit: Int64
    public let margin: Int64
    public private(set) var alerted = false

    public init(limit: Int64, margin: Int64 = 1_000_000_000) {
        self.limit = limit
        self.margin = margin
    }

    public mutating func shouldAlert(available: Int64) -> Bool {
        guard limit > 0 else { alerted = false; return false }
        if available < limit {
            if !alerted { alerted = true; return true }
        } else if available > limit + margin {
            alerted = false
        }
        return false
    }
}

public enum HistoryRetention {
    /// Records before this date are removed. nil keeps everything.
    public static func cutoff(days: Int, now: Date = .now) -> Date? {
        guard days > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: now)
    }
}
