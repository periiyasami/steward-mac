import AppKit
import Foundation
import Observation
import StewardKit

/// Live system figures, sampled every two seconds while Steward runs.
@Observable
final class StatusModel {
    struct AppUsage: Identifiable, Hashable {
        var id: String { appPath }
        let appPath: String
        let name: String
        let bundleID: String?
        let memory: UInt64
    }

    let home: URL
    var cpu: Double = 0
    var cpuHistory: [Double] = []
    var memory: MemoryStats?
    var disk: DiskStats?
    var down: Double = 0
    var up: Double = 0
    var downHistory: [Double] = []
    var uptime: TimeInterval = 0
    var battery: BatteryInfo?
    var hasBattery = false
    var topApps: [AppUsage] = []
    /// The Overview page asks for top apps only while it is on screen.
    var wantsTopApps = false
    var sampling = false

    /// Called once when free space drops under the low-space limit in Settings.
    var onLowSpace: ((Int64) -> Void)?
    private var lowSpaceAlert = LowSpaceAlert(limit: 0)

    static let historyLength = 60
    private var task: Task<Void, Never>?
    private var lastTicks: CPUTicks?
    private var lastNet: (NetworkCounters, Date)?

    init(home: URL) { self.home = home }

    func start() {
        guard task == nil else { return }
        sampling = true
        task = Task {
            while !Task.isCancelled {
                await sample()
                try? await Task.sleep(for: .seconds(Prefs.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sampling = false
    }

    /// One sample of every figure. Kernel calls run off the main thread.
    func sample() async {
        let home = home
        let wantsApps = wantsTopApps
        let s = await Task.detached { () -> (CPUTicks?, MemoryStats?, DiskStats?, NetworkCounters, BatteryInfo?, TimeInterval, [ProcessSample]) in
            (CPUTicks.read(), MemoryStats.read(), DiskStats.read(at: home), NetworkCounters.read(), BatteryInfo.read(),
             Uptime.seconds(), wantsApps ? ProcessSample.all() : [])
        }.value
        if let ticks = s.0 {
            if let last = lastTicks { cpu = CPUTicks.usage(from: last, to: ticks); push(&cpuHistory, cpu) }
            lastTicks = ticks
        }
        memory = s.1
        disk = s.2
        if let d = s.2 { checkLowSpace(available: d.available) }
        let now = Date()
        if let (prev, at) = lastNet {
            let r = NetworkCounters.rate(from: prev, to: s.3, seconds: now.timeIntervalSince(at))
            down = r.down
            up = r.up
            push(&downHistory, down)
        }
        lastNet = (s.3, now)
        battery = s.4
        hasBattery = s.4 != nil
        uptime = s.5
        if wantsApps { topApps = Self.topApps(from: s.6) }
    }

    func checkLowSpace(available: Int64) {
        lowSpaceAlert.limit = Int64(Prefs.lowDiskGB) * 1_000_000_000
        if lowSpaceAlert.shouldAlert(available: available) { onLowSpace?(available) }
    }

    private func push(_ list: inout [Double], _ value: Double) {
        list.append(value)
        if list.count > Self.historyLength { list.removeFirst(list.count - Self.historyLength) }
    }

    /// Memory per running app, helpers included, biggest first.
    static func topApps(from processes: [ProcessSample], limit: Int = 5) -> [AppUsage] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var byPath: [String: NSRunningApplication] = [:]
        for app in running { if let path = app.bundleURL?.path { byPath[path] = app } }
        var totals: [String: UInt64] = [:]
        for p in processes {
            guard let appPath = p.appPath else { continue }
            // Helpers live inside the main app (Chrome.app/Contents/Frameworks/…/Helper.app); count them for the outer app.
            let outer = byPath.keys.first { appPath == $0 || appPath.hasPrefix($0 + "/") }
            if let outer { totals[outer, default: 0] += p.memory }
        }
        return totals.compactMap { path, mem in
            byPath[path].map { AppUsage(appPath: path, name: $0.localizedName ?? (path as NSString).lastPathComponent,
                                        bundleID: $0.bundleIdentifier, memory: mem) }
        }
        .sorted { $0.memory > $1.memory }
        .prefix(limit)
        .map { $0 }
    }

    /// Asks the app to quit. Never force quits.
    func quit(_ usage: AppUsage) {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == usage.appPath }?.terminate()
    }

    static func uptimeText(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        return f.string(from: seconds) ?? ""
    }

    static func rateText(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }

    // MARK: Snapshot sample

    func loadSample(battery: Bool = true) {
        stop()
        cpu = 23
        cpuHistory = (0..<60).map { 18 + 10 * sin(Double($0) / 5) + Double($0 % 7) }
        memory = MemoryStats(total: 16 << 30, active: 6 << 30, wired: 2 << 30, compressed: 1 << 30, inactive: 3 << 30, free: 4 << 30)
        disk = DiskStats(total: 494_000_000_000, available: 212_000_000_000)
        down = 1_240_000
        up = 82_000
        downHistory = (0..<60).map { 600_000 + 500_000 * abs(sin(Double($0) / 4)) }
        uptime = 3 * 86_400 + 4 * 3_600
        self.battery = battery ? BatteryInfo(cycleCount: 312, designCapacity: 4_382, fullChargeCapacity: 3_910, chargePercent: 82,
                                             isCharging: true, isPluggedIn: true, condition: "Normal", temperatureC: 30.4) : nil
        hasBattery = battery
        let apps = URL(fileURLWithPath: "/Applications")
        topApps = [("Google Chrome", 2_840_000_000), ("Xcode", 2_120_000_000), ("Slack", 910_000_000),
                   ("Figma", 760_000_000), ("Music", 320_000_000)].map {
            AppUsage(appPath: apps.appending(path: "\($0.0).app").path, name: $0.0, bundleID: nil, memory: UInt64($0.1))
        }
    }
}
