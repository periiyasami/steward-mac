import ServiceManagement
import SwiftData
import StewardKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic. Each tab is a
/// grouped Form that sizes to its content. Every control changes what
/// Steward does; test runs use their own preferences (Prefs.store).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .status: StatusSettings()
            case .storage: StorageSettings()
            case .apps: AppsSettings()
            case .privacy: PrivacySettings()
            case .skipped: SkippedSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 560)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, status, storage, apps, privacy, skipped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .status: "System Status"
        case .storage: "Storage"
        case .apps: "Apps"
        case .privacy: "Privacy"
        case .skipped: "Skipped Items"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .status: "gauge.with.dots.needle.67percent"
        case .storage: "internaldrive"
        case .apps: "square.grid.2x2"
        case .privacy: "hand.raised"
        case .skipped: "eye.slash"
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.Key.startPage, store: Prefs.store) private var startPage = "overview"
    @AppStorage(Prefs.Key.historyDays, store: Prefs.store) private var historyDays = 0
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    var body: some View {
        Section("Startup") {
            Toggle("Open Steward at Login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
            if let loginError {
                Text(loginError).font(.callout).foregroundStyle(.orange)
            }
            Picker("Open on", selection: $startPage) {
                Text("Overview").tag("overview")
                Text("Last Page Used").tag("last")
            }
        }
        Section {
            LabeledContent("Full Disk Access") {
                HStack(spacing: Space.sm) {
                    Text(model.hasFullDiskAccess ? "On" : "Off").foregroundStyle(.secondary)
                    Button("Check Again") { model.refreshAccess() }
                }
            }
            Button("Open System Settings") { SystemSettings.openFullDiskAccess() }
        } header: {
            Text("Access")
        } footer: {
            Text("Steward reads app data folders with Full Disk Access. It only reads, and nothing leaves this Mac.")
                .foregroundStyle(.secondary)
        }
        Section {
            Picker("Keep History", selection: $historyDays) {
                Text("Forever").tag(0)
                Text("For 30 Days").tag(30)
                Text("For 90 Days").tag(90)
                Text("For 1 Year").tag(365)
            }
            .onChange(of: historyDays) { model.pruneHistory() }
            Button("Clear History…") { confirmingClear = true }
        } header: {
            Text("History")
        } footer: {
            Text("History lists past cleans. Clearing it doesn't touch anything in the Trash.").foregroundStyle(.secondary)
        }
        Section {
            Button("Reset All Settings…") { confirmingReset = true }
        } footer: {
            Text("Puts every setting back to how Steward came. History and Skipped Items stay.").foregroundStyle(.secondary)
        }
        .confirmationDialog("Clear History?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The list of past cleans is removed. Items in the Trash stay there.")
        }
        .confirmationDialog("Reset All Settings?", isPresented: $confirmingReset) {
            Button("Reset Settings", role: .destructive) { Prefs.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every setting goes back to how Steward came.")
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        guard !Store.isOverridden else { openAtLogin = on; return }
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "Approve Steward in System Settings > General > Login Items."
        }
    }
}

// MARK: - System Status

struct StatusSettings: View {
    @AppStorage(Prefs.Key.menuBar, store: Prefs.store) private var menuBar = false
    @AppStorage(Prefs.Key.menuBarShows, store: Prefs.store) private var menuBarShows = "cpu"
    @AppStorage(Prefs.Key.interval, store: Prefs.store) private var interval = 2.0
    @AppStorage(Prefs.Key.lowDiskGB, store: Prefs.store) private var lowDiskGB = 0

    var body: some View {
        Section {
            Toggle("Show in Menu Bar", isOn: $menuBar)
            Picker("Show", selection: $menuBarShows) {
                Text("CPU").tag("cpu")
                Text("Memory").tag("memory")
                Text("CPU and Memory").tag("both")
            }
            .disabled(!menuBar)
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("The menu lists memory, disk, battery, and network too. Steward keeps running when its window is closed.")
                .foregroundStyle(.secondary)
        }
        Section("Updates") {
            Picker("Refresh Every", selection: $interval) {
                Text("Second").tag(1.0)
                Text("2 Seconds").tag(2.0)
                Text("5 Seconds").tag(5.0)
            }
        }
        Section {
            Picker("Alert When Space Is Under", selection: $lowDiskGB) {
                Text("Off").tag(0)
                Text("10 GB").tag(10)
                Text("20 GB").tag(20)
                Text("50 GB").tag(50)
            }
            .onChange(of: lowDiskGB) { _, new in if new > 0, !Store.isOverridden { Notifier.requestPermission() } }
        } header: {
            Text("Low Disk Space")
        } footer: {
            Text("Steward sends one notification when space drops under the limit, and another only after space comes back.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Storage

struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.Key.threshold, store: Prefs.store) private var threshold = Int(LargeFileFilter.thresholds[0])
    @AppStorage(Prefs.Key.largeAge, store: Prefs.store) private var age = FileAge.any.rawValue
    @AppStorage(Prefs.Key.diskMapStart, store: Prefs.store) private var diskMapStart = ""
    @AppStorage(Prefs.Key.destination, store: Prefs.store) private var destination = CleanDestination.trash.rawValue
    @AppStorage(Prefs.Key.holdingDays, store: Prefs.store) private var holdingDays = 7
    @AppStorage(Prefs.Key.duplicateMinSize, store: Prefs.store) private var duplicateMinSize = Int(DuplicateFinder.sizeChoices[1])

    var body: some View {
        Section {
            Picker("Cleaned Items Go To", selection: $destination) {
                ForEach(CleanDestination.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            if destination == CleanDestination.holding.rawValue {
                Picker("Delete Held Items After", selection: $holdingDays) {
                    ForEach(CleanDestination.holdingChoices, id: \.self) { Text("\($0) \($0 == 1 ? "Day" : "Days")").tag($0) }
                }
                .onChange(of: holdingDays) { model.purgeHolding() }
            }
        } header: {
            Text("Cleaning")
        } footer: {
            Text(destination == CleanDestination.holding.rawValue
                 ? "Items wait in Steward's holding area, where you can put them back, then Steward deletes them for good. Space frees up without emptying the Trash."
                 : "Items move to the Trash. The space comes back when you empty it.")
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(ScanCategory.allCases.filter { !$0.isDeveloper }, id: \.self) { CategoryToggle(category: $0) }
        } header: {
            Text("Smart Scan")
        } footer: {
            Text("Smart Scan looks only in the categories that are on.").foregroundStyle(.secondary)
        }
        Section {
            ForEach(ScanCategory.allCases.filter(\.isDeveloper), id: \.self) { CategoryToggle(category: $0) }
        } header: {
            Text("Developer Cleanup")
        } footer: {
            Text("Unticked categories are found but not chosen for you. Old Project Dependencies looks in Developer, Projects, Code, Documents, Desktop, and similar folders.")
                .foregroundStyle(.secondary)
        }
        Section("Large & Old Files") {
            Picker("Show Files Over", selection: $threshold) {
                ForEach(LargeFileFilter.thresholds, id: \.self) { Text(Bytes.text($0)).tag(Int($0)) }
            }
            .onChange(of: threshold) { _, new in model.largeFiles.threshold = Int64(new) }
            Picker("Last Opened", selection: $age) {
                ForEach(FileAge.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: age) { _, new in model.largeFiles.age = FileAge(rawValue: new) ?? .any }
        }
        Section("Duplicates") {
            Picker("Compare Files Over", selection: $duplicateMinSize) {
                ForEach(DuplicateFinder.sizeChoices, id: \.self) { Text(Bytes.text($0)).tag(Int($0)) }
            }
            .onChange(of: duplicateMinSize) { _, new in model.duplicates.minSize = Int64(new) }
        }
        Section("Disk Map") {
            LabeledContent("Start In") {
                HStack(spacing: Space.sm) {
                    Text(diskMapStart.isEmpty ? "Home Folder" : model.display(diskMapStart))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                    if !diskMapStart.isEmpty { Button("Use Home Folder") { diskMapStart = "" } }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        diskMapStart = url.path
    }
}

struct CategoryToggle: View {
    let category: ScanCategory
    @AppStorage private var on: Bool

    init(category: ScanCategory) {
        self.category = category
        _on = AppStorage(wrappedValue: true, ScanSettings.key(category), store: Prefs.store)
    }

    var body: some View {
        Toggle(isOn: $on) {
            Label(category.title, systemImage: category.symbol)
            Text(category.reason)
        }
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @AppStorage(Prefs.Key.unusedPeriod, store: Prefs.store) private var unusedPeriod = 6
    @AppStorage(Prefs.Key.updatesAllowed, store: Prefs.store) private var updatesAllowed = false

    var body: some View {
        Section("Unused Apps") {
            Picker("Count an App as Unused After", selection: $unusedPeriod) {
                Text("3 Months").tag(3)
                Text("6 Months").tag(6)
                Text("12 Months").tag(12)
            }
        }
        Section {
            Toggle("Allow Update Checks", isOn: $updatesAllowed)
        } header: {
            Text("Updates")
        } footer: {
            Text("Lets Apps > Updates contact each app maker's update server when you press Check for Updates. Nothing about you or Steward is sent.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @AppStorage(Prefs.Key.tickCache, store: Prefs.store) private var cache = true
    @AppStorage(Prefs.Key.tickCookies, store: Prefs.store) private var cookies = false
    @AppStorage(Prefs.Key.tickHistory, store: Prefs.store) private var history = false
    @AppStorage(Prefs.Key.showApple, store: Prefs.store) private var showApple = false

    var body: some View {
        Section {
            Toggle(isOn: $cache) { Text("Caches"); Text(BrowserDataKind.cache.effect) }
            Toggle(isOn: $cookies) { Text("Cookies"); Text(BrowserDataKind.cookies.effect) }
            Toggle(isOn: $history) { Text("History"); Text(BrowserDataKind.history.effect) }
        } header: {
            Text("Browser Data Ticked for You")
        } footer: {
            Text("You still see every item in Review before anything moves to the Trash.").foregroundStyle(.secondary)
        }
        Section("Background Activity") {
            Toggle("Show Apple's Background Jobs", isOn: $showApple)
        }
    }
}

// MARK: - Skipped Items

struct SkippedSettings: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var model
    @Query(sort: \SkipRule.addedAt, order: .reverse) private var rules: [SkipRule]

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("No skipped items.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack {
                    Text(model.display(rule.path)).lineLimit(1).truncationMode(.middle).help(rule.path)
                    Spacer()
                    Button("Remove") {
                        context.delete(rule)
                        try? context.save()
                    }
                    .help("Let Smart Scan choose this item again")
                }
            }
        } header: {
            Text("Skipped Items")
        } footer: {
            Text("Steward never chooses these. Right-click an item in Smart Scan and choose Always Skip to add one.")
                .foregroundStyle(.secondary)
        }
    }
}
