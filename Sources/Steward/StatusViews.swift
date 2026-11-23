import AppKit
import StewardKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Space.lg, alignment: .top)], alignment: .leading, spacing: Space.lg) {
                    StatCard(title: "CPU", symbol: "cpu", value: "\(Int(s.cpu.rounded()))%",
                             detail: "Across all cores", fraction: s.cpu / 100, history: s.cpuHistory.map { $0 / 100 })
                    if let m = s.memory {
                        StatCard(title: "Memory", symbol: "memorychip",
                                 value: "\(Bytes.text(Int64(m.used))) of \(Bytes.text(Int64(m.total)))",
                                 detail: "Apps \(Bytes.text(Int64(m.active))) · Wired \(Bytes.text(Int64(m.wired))) · Compressed \(Bytes.text(Int64(m.compressed)))",
                                 fraction: m.usedFraction)
                    }
                    if let d = s.disk {
                        StatCard(title: "Disk", symbol: "internaldrive", value: "\(Bytes.text(d.available)) available",
                                 detail: "\(Bytes.text(d.used)) used of \(Bytes.text(d.total))", fraction: d.usedFraction)
                    }
                    StatCard(title: "Network", symbol: "arrow.up.arrow.down",
                             value: "↓ \(StatusModel.rateText(s.down))", detail: "↑ \(StatusModel.rateText(s.up))",
                             history: normalized(s.downHistory))
                    StatCard(title: "Uptime", symbol: "clock", value: StatusModel.uptimeText(s.uptime), detail: "Since this Mac last started")
                    if let b = s.battery {
                        StatCard(title: "Battery", symbol: "battery.75percent",
                                 value: b.chargePercent.map { "\($0)%" } ?? "—",
                                 detail: [b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in" : "On battery"),
                                          b.healthPercent.map { "Health \($0)%" }].compactMap { $0 }.joined(separator: " · "),
                                 fraction: b.chargePercent.map { Double($0) / 100 })
                    }
                }
                ModuleSummaries()
                TopAppsSection(status: s)
            }
            .padding(Space.margin)
        }
        .navigationTitle("Overview")
        .onAppear {
            s.wantsTopApps = true
            s.start()
            Task { await s.sample() }
            // Light background loads so the module summaries have figures.
            guard !Store.isOverridden else { return }
            if !model.uninstaller.hasLoaded { model.uninstaller.load() }
            if !model.loginItems.hasLoaded { model.loginItems.load() }
            if !model.browserData.hasLoaded { model.browserData.load() }
        }
        .onDisappear { s.wantsTopApps = false }
    }

    private func normalized(_ values: [Double]) -> [Double] {
        let top = max(values.max() ?? 1, 1)
        return values.map { $0 / top }
    }
}

/// One tile per module with its headline figure; a click opens the page.
struct ModuleSummaries: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Your Mac at a Glance").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.md, alignment: .top)], alignment: .leading, spacing: Space.md) {
                SummaryTile(module: .storage, value: storageValue, detail: storageDetail) { model.sidebar = .scan }
                SummaryTile(module: .apps, value: appsValue, detail: "Not opened in \(Prefs.unusedPeriod) months") { model.sidebar = .unusedApps }
                SummaryTile(module: .startup, value: startupValue, detail: "Background agents that start at login") { model.sidebar = .loginItems }
                SummaryTile(module: .privacy, value: privacyValue, detail: "Browser caches to clear") { model.sidebar = .browserData }
            }
        }
    }

    private var storageValue: String {
        model.items.isEmpty ? "Run Smart Scan" : "\(Bytes.text(model.items.reduce(0) { $0 + $1.size })) to clean"
    }
    private var storageDetail: String {
        model.scannedAt.map { "Scanned \($0.formatted(.relative(presentation: .named)))" } ?? "Find caches, logs, and build files"
    }
    private var appsValue: String {
        let un = model.uninstaller
        guard un.hasLoaded, !un.loading else { return "Looking…" }
        let n = un.unused(UnusedPeriod(rawValue: Prefs.unusedPeriod) ?? .six).count
        return n == 0 ? "No unused apps" : "\(n) unused \(n == 1 ? "app" : "apps")"
    }
    private var startupValue: String {
        let li = model.loginItems
        guard li.hasLoaded, !li.loading else { return "Looking…" }
        let on = li.userRows.filter(\.isOn).count
        return "\(on) login \(on == 1 ? "agent" : "agents")"
    }
    private var privacyValue: String {
        let b = model.browserData
        guard b.hasLoaded, !b.loading else { return "Looking…" }
        return Bytes.text(b.items.filter { $0.kind == .cache }.reduce(0) { $0 + $1.size })
    }
}

struct SummaryTile: View {
    let module: Module
    let value: String
    let detail: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.md) {
                Image(systemName: module.symbol)
                    .font(.title2)
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 40, height: 40)
                    .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.shortTitle).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(Space.md)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(hovering ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(module.title)")
        .accessibilityLabel("\(module.title): \(value). \(detail)")
    }
}

/// One figure: a label, a value, an optional bar, and an optional sparkline.
struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var fraction: Double? = nil
    var history: [Double] = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let fraction {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(fraction > 0.9 ? .orange : Palette.accent)
                        .accessibilityLabel("\(title) \(Int(fraction * 100)) percent")
                }
                if history.count > 1 {
                    Sparkline(values: history)
                        .frame(height: 32)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(Space.xs)
        } label: {
            Label(title, systemImage: symbol)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small line of recent values, 0 to 1.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(1, max(0, v)))))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(Palette.accent.opacity(0.15)))
            context.stroke(line, with: .color(Palette.accent), lineWidth: 1.5) // grid: ok stroke width, not spacing
        }
    }
}

struct TopAppsSection: View {
    let status: StatusModel

    var body: some View {
        GroupBox {
            if status.topApps.isEmpty {
                Text("Measuring…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(Space.xs)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(status.topApps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider() }
                        HStack(spacing: Space.md) {
                            AppIcon(url: URL(fileURLWithPath: app.appPath), size: 24)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Text(Bytes.text(Int64(app.memory))).monospacedDigit().foregroundStyle(.secondary)
                            Button("Quit") { status.quit(app) }
                                .help("Ask \(app.name) to quit")
                        }
                        .padding(.vertical, Space.sm)
                        .padding(.horizontal, Space.xs)
                    }
                }
            }
        } label: {
            Label("Using the Most Memory", systemImage: "chart.bar")
        }
    }
}

struct BatteryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        Group {
            if let b = s.battery {
                Form {
                    Section {
                        LabeledContent("Health") {
                            Text(b.healthPercent.map { "\($0)%" } ?? "Unknown").monospacedDigit()
                        }
                        if let health = b.healthPercent {
                            ProgressView(value: min(1, Double(health) / 100))
                                .tint(health < 80 ? .orange : Palette.accent)
                                .accessibilityLabel("Battery health \(health) percent")
                        }
                        LabeledContent("Condition", value: b.condition ?? "Normal")
                        LabeledContent("Cycle Count", value: b.cycleCount.map(String.init) ?? "Unknown")
                    } header: {
                        Text("Health")
                    } footer: {
                        Text("Health compares what the battery holds now with what it held when new.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Charge") {
                        LabeledContent("Charge", value: b.chargePercent.map { "\($0)%" } ?? "Unknown")
                        LabeledContent("Power Source", value: b.isPluggedIn ? (b.isCharging ? "Power adapter, charging" : "Power adapter") : "Battery")
                        if let full = b.fullChargeCapacity { LabeledContent("Full Charge Capacity", value: "\(full) mAh") }
                        if let design = b.designCapacity { LabeledContent("Design Capacity", value: "\(design) mAh") }
                        if let t = b.temperatureC { LabeledContent("Temperature", value: String(format: "%.1f °C", t)) }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("This Mac has no battery.", systemImage: "powerplug",
                                       description: Text("Battery health appears here on Mac laptops."))
            }
        }
        .navigationTitle("Battery")
        .onAppear { s.start() }
    }
}

/// The menu bar item, built with AppKit's NSStatusItem: CPU in the bar,
/// every figure in its menu. It follows the "status.menuBar" setting.
/// (SwiftUI's MenuBarExtra looped during launch; see docs/FIXLOG.md.)
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()
    private var item: NSStatusItem?
    private weak var model: AppModel?
    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    static var isEnabled: Bool { Prefs.menuBar }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Test and snapshot runs never add a menu bar item.
        guard !Store.isOverridden else { return }
        update()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// Adds or removes the item to match the setting.
    func update() {
        if Self.isEnabled, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Steward")
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            model?.status.start()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
            }
            refreshTitle()
        } else if !Self.isEnabled, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            timer?.invalidate()
            timer = nil
        }
    }

    var isShowing: Bool { item != nil }

    private func refreshTitle() {
        guard let s = model?.status else { return }
        let cpu = "\(Int(s.cpu.rounded()))%"
        let mem = s.memory.map { "\(Int(($0.usedFraction * 100).rounded()))%" } ?? "–"
        switch Prefs.menuBarShows {
        case "memory": item?.button?.title = " \(mem)"
        case "both": item?.button?.title = " \(cpu) · \(mem)"
        default: item?.button?.title = " \(cpu)"
        }
        item?.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    /// Rebuilds the menu each time it opens, so the figures are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        for line in Self.lines(model.status) {
            let entry = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Steward", action: #selector(openSteward), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Steward", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    static func lines(_ s: StatusModel) -> [String] {
        var lines = ["CPU \(Int(s.cpu.rounded()))%"]
        if let m = s.memory { lines.append("Memory \(Bytes.text(Int64(m.used))) of \(Bytes.text(Int64(m.total)))") }
        if let d = s.disk { lines.append("Disk \(Bytes.text(d.available)) available") }
        if let b = s.battery, let c = b.chargePercent { lines.append("Battery \(c)%\(b.isCharging ? ", charging" : "")") }
        lines.append("Network ↓ \(StatusModel.rateText(s.down)) ↑ \(StatusModel.rateText(s.up))")
        return lines
    }

    @objc private func openSteward() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        model?.sidebar = .overview
    }
}
