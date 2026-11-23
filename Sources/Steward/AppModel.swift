import AppKit
import Foundation
import SwiftData
import StewardKit

enum ScanPhase: Equatable {
    case idle
    case running(current: ScanCategory?, count: Int, bytes: Int64)
    case results
    case done
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let container: ModelContainer
    /// The page on screen. (Named for the old sidebar; navigation is now the module bar.)
    var sidebar: SidebarItem? = .overview {
        didSet {
            guard let sidebar, let module = sidebar.module else { return }
            Prefs.store.set(sidebar.rawValue, forKey: Prefs.Key.lastPage)
            lastPageByModule[module] = sidebar
        }
    }
    /// Each module opens on the page last used in it.
    var lastPageByModule: [Module: SidebarItem] = [:]

    var currentModule: Module? { sidebar?.module }

    func show(_ module: Module) {
        sidebar = lastPageByModule[module] ?? module.pages.first
    }

    /// Next or previous page within the current module, wrapping around.
    func movePage(by offset: Int) {
        guard let module = currentModule, let page = sidebar, let i = module.pages.firstIndex(of: page) else { return }
        let pages = module.pages
        sidebar = pages[(i + offset + pages.count) % pages.count]
    }
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    /// The home folder Steward works in. APP_HOME points tests at a fixture.
    let home: URL
    /// APP_TRASH's folder, which stands in for the Trash in the self-test.
    let fixedTrash: TrashMover?
    /// Steward's holding area, next to the database.
    let holding: HoldingArea
    let holdingModel: HoldingModel
    /// Where a clean sends items right now (Settings > Storage).
    var destination: CleanDestination { Prefs.destination }
    var trash: TrashMover {
        if destination == .holding { return holding }
        return fixedTrash ?? SystemTrash()
    }
    let largeFiles: LargeFilesModel
    let duplicates: DuplicatesModel
    let diskMap: DiskMapModel
    let uninstaller: UninstallerModel
    let loginItems: LoginItemsModel
    let status: StatusModel
    let permissions: PermissionsModel
    let updates = UpdatesModel()
    let background: BackgroundModel
    let browserData: BrowserDataModel
    let recentItems: RecentItemsModel

    // Smart Scan
    var phase: ScanPhase = .idle
    var items: [ScanItem] = []
    var ticked: Set<String> = []
    var notScanned: [URL] = []
    /// Selected rows in the results: item paths, and "cat:<category>" for category rows.
    var scanSelection: Set<String> = []
    /// When the shown results were scanned (S-052).
    var scannedAt: Date?
    /// App Caches whose app is open: item path to app name. Left unticked.
    var openOwners: [String: String] = [:]
    /// The apps open right now. The self-test replaces it.
    var runningApps: () -> [RunningApp] = {
        NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { RunningApp(bundleID: $0, name: app.localizedName ?? $0) }
        }
    }

    // Review and cleaning, shared by every page.
    var review: ReviewSession?
    var lastClean: CleanSummary?
    var lastRecord: CleanRecord?
    var cleaning = false

    var hasFullDiskAccess: Bool
    var accessSkipped: Bool {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(accessSkipped, forKey: "access.skipped") } }
    }
    var available: Int64?

    private var scanTask: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        let env = ProcessInfo.processInfo.environment
        if let path = env["APP_HOME"], !path.isEmpty {
            home = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        if let path = env["APP_TRASH"], !path.isEmpty {
            fixedTrash = FolderTrash(folder: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            fixedTrash = nil
        }
        holding = HoldingArea(folder: Store.holdingURL)
        holdingModel = HoldingModel(area: holding)
        largeFiles = LargeFilesModel(home: home)
        duplicates = DuplicatesModel(home: home)
        diskMap = DiskMapModel(home: home)
        // A fixture home (APP_HOME) only looks for apps inside it.
        let appFolders = (env["APP_HOME"] ?? "").isEmpty ? AppCatalog.defaultFolders(home: home) : [home.appending(path: "Applications")]
        uninstaller = UninstallerModel(home: home, folders: appFolders)
        // A fixture home never touches the real launchd.
        let fixture = !(env["APP_HOME"] ?? "").isEmpty
        loginItems = LoginItemsModel(
            home: home, control: fixture ? FakeLaunchControl() : SystemLaunchControl(),
            systemFolders: fixture ? [] : [(URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
                                           (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon)],
            appFolders: appFolders)
        status = StatusModel(home: home)
        // A fixture home reads only its own TCC database and never resets the real Quick Look cache.
        permissions = PermissionsModel(databases: fixture ? [TCCReader.userDatabase(home: home)]
                                                          : [TCCReader.userDatabase(home: home), TCCReader.systemDatabase])
        background = BackgroundModel(home: home, appFolders: appFolders)
        browserData = BrowserDataModel(home: home)
        let fakeReset: @Sendable () -> Bool = { true }
        recentItems = RecentItemsModel(home: home, resetQuickLook: fixture ? fakeReset : RecentItemsModel.realQuickLookReset)
        if Prefs.startPage == "last", let last = Prefs.lastPage { sidebar = last }
        hasFullDiskAccess = AccessCheck.hasFullDiskAccess()
        accessSkipped = Store.isOverridden ? false : UserDefaults.standard.bool(forKey: "access.skipped")
        refreshAvailable()
        pruneHistory()
        purgeHolding()
        status.onLowSpace = { [weak self] available in self?.lowSpace(available) }
    }

    // MARK: Holding area

    /// Deletes items that have waited in the holding area longer than the setting.
    func purgeHolding(now: Date = .now) {
        let area = holding, cutoff = now.addingTimeInterval(-Double(Prefs.holdingDays) * 86_400)
        Task {
            let outcome = await Task.detached { () -> DeleteOutcome in
                area.tidy()
                return area.purge(heldBefore: cutoff)
            }.value
            if !outcome.deleted.isEmpty { refreshAvailable() }
            if holdingModel.hasLoaded { holdingModel.load() }
        }
    }

    /// Puts items back from the holding area or the Trash, and drops them from History.
    func putBack(_ moved: [MovedItem]) {
        guard !moved.isEmpty else { return }
        let outcome = Cleaner(home: home, trash: trash).undo(moved)
        let restored = Set(outcome.restored.map(\.inTrash.path))
        let context = container.mainContext
        let entries = (try? context.fetch(FetchDescriptor<CleanEntry>())) ?? []
        var touched = Set<UUID>()
        for entry in entries where restored.contains(entry.trashPath) {
            if let record = entry.record { touched.insert(record.uuid) }
            context.delete(entry)
        }
        try? context.save()
        let records = (try? context.fetch(FetchDescriptor<CleanRecord>())) ?? []
        for record in records where touched.contains(record.uuid) && record.entries.isEmpty { context.delete(record) }
        try? context.save()
        if let summary = lastClean, summary.moved.contains(where: { restored.contains($0.inTrash.path) }) {
            lastClean = nil
            lastRecord = nil
            if summary.source == .smartScan, phase == .done { phase = .idle }
        }
        largeFiles.restored(Set(outcome.restored.map(\.original.path)))
        holding.tidy()
        holdingModel.load()
        let skipped = outcome.skipped.count
        holdingModel.message = skipped == 0
            ? "Put back \(Count.items(outcome.restored.count))."
            : "Put back \(Count.items(outcome.restored.count)). \(Count.items(skipped)) couldn't go back: the original place is taken or the item is gone."
        refreshAvailable()
    }

    /// Put Back for the rows selected on the Trash & Holding page.
    func putBackSelection() {
        let selection = holdingModel.selection
        var moved = holdingModel.items.filter { selection.contains($0.id) }.compactMap(\.moved)
        let trashPaths = Set(selection.filter { $0.hasPrefix(HoldingModel.trashPrefix) }.map { String($0.dropFirst(HoldingModel.trashPrefix.count)) })
        if !trashPaths.isEmpty {
            let entries = (try? container.mainContext.fetch(FetchDescriptor<CleanEntry>())) ?? []
            moved += entries.filter { trashPaths.contains($0.trashPath) }.map {
                MovedItem(original: URL(fileURLWithPath: $0.originalPath), inTrash: URL(fileURLWithPath: $0.trashPath), size: $0.size)
            }
        }
        holdingModel.selection = []
        putBack(moved)
    }

    var canPutBack: Bool { sidebar == .holding && !holdingModel.selection.isEmpty }
    var canDeleteHeld: Bool { sidebar == .holding && !holdingModel.selectedItems.isEmpty }

    /// Deletes held items for good.
    func deleteHeld(_ items: [HeldItem]) {
        let area = holding
        Task {
            let outcome = await Task.detached { area.delete(items) }.value
            holdingModel.message = outcome.failed.isEmpty
                ? "Deleted \(Count.items(outcome.deleted.count)), \(Bytes.text(outcome.bytes)) freed."
                : "Deleted \(Count.items(outcome.deleted.count)). \(Count.items(outcome.failed.count)) couldn't be deleted."
            holdingModel.load()
            refreshAvailable()
        }
    }

    /// Empties the system Trash through Finder.
    func emptyTrash() {
        holdingModel.message = TrashControl.emptyTrash() ?? "The Trash is empty."
        refreshAvailable()
    }

    // MARK: History retention

    /// Removes History records older than the retention setting. Files in the Trash are not touched.
    func pruneHistory(now: Date = .now) {
        guard let cutoff = HistoryRetention.cutoff(days: Prefs.historyDays, now: now) else { return }
        let old = (try? container.mainContext.fetch(FetchDescriptor<CleanRecord>(predicate: #Predicate { $0.date < cutoff }))) ?? []
        old.forEach { container.mainContext.delete($0) }
        try? container.mainContext.save()
    }

    /// Empties History. Files in the Trash are not touched.
    func clearHistory() {
        let all = (try? container.mainContext.fetch(FetchDescriptor<CleanRecord>())) ?? []
        all.forEach { container.mainContext.delete($0) }
        try? container.mainContext.save()
        lastRecord = nil
    }

    /// The last low-space alert, for the self-test.
    var lastLowSpaceAlert: Int64?

    private func lowSpace(_ available: Int64) {
        lastLowSpaceAlert = available
        guard !Store.isOverridden else { return }
        Notifier.post(title: "Your disk is almost full",
                      body: "\(Bytes.text(available)) available. Open Steward to find space you can free.")
    }

    var showsAccessPage: Bool { !hasFullDiskAccess && !accessSkipped }

    func refreshAccess() {
        hasFullDiskAccess = AccessCheck.hasFullDiskAccess()
    }

    func refreshAvailable() {
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        available = values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Smart Scan

    var isScanning: Bool { if case .running = phase { true } else { false } }

    func startScan() {
        guard !isScanning else { return }
        scanTask?.cancel()
        items = []
        ticked = []
        notScanned = []
        openOwners = [:]
        let running = runningApps()
        if lastClean?.source == .smartScan { lastClean = nil }
        phase = .running(current: nil, count: 0, bytes: 0)
        let scanner = Scanner(home: home, skipped: skipList(), categories: ScanSettings.enabledCategories)
        scanTask = Task {
            var count = 0
            var bytes: Int64 = 0
            var current: ScanCategory?
            for await event in scanner.events() {
                if Task.isCancelled { break }
                switch event {
                case .started(let category):
                    current = category
                case .found(let item):
                    items.append(item)
                    if noteOpenOwner(item, running: running) == nil, item.category.isRecommended { ticked.insert(item.id) }
                    count += 1
                    bytes += item.size
                case .notScanned(let url):
                    if !notScanned.contains(url) { notScanned.append(url) }
                }
                phase = .running(current: current, count: count, bytes: bytes)
            }
            finishScan()
        }
    }

    private func finishScan() {
        phase = .results
        scannedAt = .now
        LastScan.save(items: items, notScanned: notScanned, date: .now)
    }

    /// Ends the scan within a moment and keeps what was found.
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { finishScan() }
    }

    /// Shows the last saved Smart Scan result, without items that are gone (S-052).
    func restoreLastScan() {
        guard phase == .idle, let saved = LastScan.load() else { return }
        let fm = FileManager.default
        let skipped = skipList()
        items = saved.items.filter { fm.fileExists(atPath: $0.url.path) && !skipped.matches($0.url) }
        openOwners = [:]
        let running = runningApps()
        ticked = Set(items.filter { noteOpenOwner($0, running: running) == nil && $0.category.isRecommended }.map(\.id))
        notScanned = saved.notScanned
        scannedAt = saved.date
        phase = .results
    }

    /// Records and returns the open app that owns an App Caches item.
    @discardableResult
    private func noteOpenOwner(_ item: ScanItem, running: [RunningApp]) -> String? {
        guard item.category == .appCaches, let owner = CacheOwner.runningOwner(ofCacheNamed: item.name, running: running) else { return nil }
        openOwners[item.id] = owner.name
        return owner.name
    }

    var categories: [ScanCategory] {
        ScanCategory.allCases.filter { c in items.contains { $0.category == c } }
    }

    func items(in category: ScanCategory) -> [ScanItem] {
        items.filter { $0.category == category }.sorted { $0.size > $1.size }
    }

    var tickedItems: [ScanItem] { items.filter { ticked.contains($0.id) } }
    var tickedBytes: Int64 { tickedItems.reduce(0) { $0 + $1.size } }

    func toggle(_ item: ScanItem) {
        if ticked.contains(item.id) { ticked.remove(item.id) } else { ticked.insert(item.id) }
    }

    /// Return or Space in the results: tick the selected rows, or untick them when all are ticked.
    func toggleScanSelection() {
        var ids = Set<String>()
        for sel in scanSelection {
            if sel.hasPrefix("cat:"), let c = ScanCategory(rawValue: String(sel.dropFirst(4))) {
                ids.formUnion(items(in: c).map(\.id))
            } else {
                ids.insert(sel)
            }
        }
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: ticked) { ticked.subtract(ids) } else { ticked.formUnion(ids) }
    }

    func setTicked(_ category: ScanCategory, _ on: Bool) {
        for item in items(in: category) {
            if on { ticked.insert(item.id) } else { ticked.remove(item.id) }
        }
    }

    /// Opens Review for the ticked Smart Scan items.
    func openReview() {
        guard !tickedItems.isEmpty, !isScanning else { return }
        let rows = tickedItems.sorted { $0.size > $1.size }.map { item in
            let reason = openOwners[item.id].map { "\($0) is open. Quit it before moving its cache." }
                ?? "\(item.category.title): \(item.category.reason)"
            return Candidate(url: item.url, size: item.size, reason: reason, group: item.category.title)
        }
        review = ReviewSession(source: .smartScan, rows: rows)
    }

    // MARK: Review and Move to Trash

    var canOpenReview: Bool {
        guard review == nil else { return false }
        switch sidebar ?? .scan {
        case .scan: return !tickedItems.isEmpty && !isScanning
        case .largeFiles: return !largeFiles.tickedVisible.isEmpty
        case .duplicates: return !duplicates.tickedFiles.isEmpty
        case .diskMap: return !diskMap.collected.isEmpty
        case .uninstaller: return uninstaller.mode == .apps ? uninstaller.canUninstall : !uninstaller.tickedOrphans.isEmpty
        case .browserData: return !browserData.tickedItems.isEmpty
        case .recentItems: return !recentItems.ticked.isEmpty
        default: return false
        }
    }

    func openReviewForCurrentPage() {
        guard canOpenReview else { return }
        switch sidebar ?? .scan {
        case .scan: openReview()
        case .largeFiles: review = largeFiles.reviewSession()
        case .duplicates: review = duplicates.reviewSession()
        case .diskMap: review = diskMap.reviewSession()
        case .uninstaller:
            if uninstaller.mode == .leftovers {
                review = uninstaller.orphanSession()
            } else {
                Task { review = await uninstaller.uninstallSession() }
            }
        case .browserData: review = browserData.reviewSession()
        case .recentItems: review = recentItems.reviewSession()
        default: break
        }
    }

    func moveToTrash(_ session: ReviewSession, undoManager: UndoManager?) {
        let chosen = session.tickedRows
        guard !chosen.isEmpty, !cleaning else { return }
        cleaning = true
        let cleaner = Cleaner(home: home, trash: trash)
        let requests = chosen.map { CleanRequest(url: $0.url, size: $0.size, isAppBundle: $0.isAppBundle) }
        Task {
            let outcome = await Task.detached { cleaner.moveToTrash(requests) }.value
            finishClean(outcome, chosen: chosen, source: session.source, undoManager: undoManager)
        }
    }

    private func finishClean(_ outcome: CleanOutcome, chosen: [Candidate], source: CleanSource, undoManager: UndoManager?) {
        cleaning = false
        review = nil
        let byPath = Dictionary(chosen.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        if !outcome.moved.isEmpty {
            let record = CleanRecord()
            container.mainContext.insert(record)
            for moved in outcome.moved {
                let entry = CleanEntry(
                    originalPath: moved.original.path, trashPath: moved.inTrash.path, size: moved.size,
                    categoryTitle: byPath[moved.original.path]?.group ?? "")
                container.mainContext.insert(entry)
                entry.record = record
            }
            try? container.mainContext.save()
            lastRecord = record
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.undoLastClean() }
            }
            undoManager?.setActionName(destination.action)
        }
        let movedPaths = Set(outcome.moved.map(\.original.path))
        lastClean = CleanSummary(
            source: source, moved: outcome.moved, failed: outcome.failed,
            candidates: chosen.filter { movedPaths.contains($0.url.path) })
        pagesRemoved(movedPaths, source: source)
        if holdingModel.hasLoaded { holdingModel.load() }
        refreshAvailable()
    }

    /// Each page drops what moved to the Trash from its own list.
    private func pagesRemoved(_ paths: Set<String>, source: CleanSource) {
        items.removeAll { paths.contains($0.url.path) }
        ticked.subtract(paths)
        largeFiles.removed(paths)
        duplicates.removed(paths)
        diskMap.removed(paths)
        uninstaller.removed(paths)
        loginItems.removed(paths)
        browserData.removed(paths)
        recentItems.removed(paths)
        if source == .smartScan {
            phase = .done
            LastScan.save(items: items, notScanned: notScanned, date: scannedAt ?? .now)
        }
    }

    var canUndoLastClean: Bool { lastClean.map { !$0.undone && !$0.moved.isEmpty } ?? false }

    /// Puts the last clean's items back where they were.
    func undoLastClean() {
        guard var summary = lastClean, !summary.undone else { return }
        let outcome = Cleaner(home: home, trash: trash).undo(summary.moved)
        summary.undone = true
        lastClean = summary
        if let record = lastRecord {
            let restored = Set(outcome.restored.map(\.original.path))
            for entry in record.entries where restored.contains(entry.originalPath) {
                container.mainContext.delete(entry)
            }
            if record.entries.allSatisfy({ restored.contains($0.originalPath) }) {
                container.mainContext.delete(record)
            }
            try? container.mainContext.save()
            lastRecord = nil
        }
        let restored = Set(outcome.restored.map(\.original.path))
        pagesRestored(summary.candidates.filter { restored.contains($0.url.path) }, source: summary.source)
        holding.tidy()
        if holdingModel.hasLoaded { holdingModel.load() }
        refreshAvailable()
    }

    private func pagesRestored(_ candidates: [Candidate], source: CleanSource) {
        let paths = Set(candidates.map(\.url.path))
        largeFiles.restored(paths)
        duplicates.restored(paths)
        if source == .diskMap { diskMap.restored() }
        if source == .uninstaller || source == .leftovers { uninstaller.restored() }
        if source == .loginItems { loginItems.restored() }
        if source == .browserData, !Store.isOverridden { browserData.load() }
        if source == .recentItems, !Store.isOverridden { recentItems.load() }
    }

    /// The selected files on the current page, for Show in Finder and Quick Look.
    var selectedURLs: [URL] {
        switch sidebar ?? .scan {
        case .scan: items.filter { scanSelection.contains($0.id) }.map(\.url)
        case .largeFiles: largeFiles.selectedURLs
        case .duplicates: duplicates.selectedURLs
        case .holding: holdingModel.selectedURLs
        case .diskMap: diskMap.current?.children.filter { $0.id == diskMap.highlighted && !$0.isOther }.map(\.url) ?? []
        case .uninstaller: uninstaller.mode == .apps ? (uninstaller.selected.map { [$0.app.url] } ?? []) : []
        case .loginItems: loginItems.rows.filter { $0.id == loginItems.selection }.map(\.item.plist)
        case .background: background.rows.filter { $0.id == background.selection }.compactMap { $0.process.map { URL(fileURLWithPath: $0.path) } }
        case .unusedApps, .permissions, .updates, .browserData, .recentItems, .overview, .battery, .history: []
        }
    }

    /// Whether the current page has something running that Stop can end.
    var canStop: Bool {
        switch sidebar ?? .scan {
        case .scan: isScanning
        case .largeFiles: largeFiles.scanning
        case .duplicates: duplicates.scanning
        case .diskMap: diskMap.measuring
        default: false
        }
    }

    func stopCurrent() {
        switch sidebar ?? .scan {
        case .scan: stopScan()
        case .largeFiles: largeFiles.stop()
        case .duplicates: duplicates.stop()
        case .diskMap: diskMap.stop()
        default: break
        }
    }

    func quickLookSelection() {
        switch sidebar ?? .scan {
        case .largeFiles: largeFiles.preview = largeFiles.preview == nil ? largeFiles.selectedURLs.first : nil
        case .duplicates: duplicates.preview = duplicates.preview == nil ? duplicates.selectedURLs.first : nil
        default: break
        }
    }

    // MARK: Skipped Items

    func skipList() -> SkipList {
        let rules = (try? container.mainContext.fetch(FetchDescriptor<SkipRule>())) ?? []
        return SkipList(rules.map(\.path))
    }

    func alwaysSkip(_ url: URL) {
        let path = url.standardizedFileURL.path
        let existing = (try? container.mainContext.fetch(FetchDescriptor<SkipRule>(predicate: #Predicate { $0.path == path }))) ?? []
        if existing.isEmpty {
            container.mainContext.insert(SkipRule(path: path))
            try? container.mainContext.save()
        }
        items.removeAll { $0.url.path == url.path }
        ticked.remove(url.path)
    }

    // MARK: Display helpers

    /// "~/Library/Caches/com.example" for paths in the home folder.
    func display(_ url: URL) -> String { display(url.path) }

    func display(_ path: String) -> String {
        guard let rel = PathGuard.relativePath(of: URL(fileURLWithPath: path), in: home) else { return path }
        return rel.isEmpty ? "~" : "~/" + rel
    }
}

/// Which Smart Scan categories run (Settings > General, S-061).
enum ScanSettings {
    static var store: UserDefaults { Prefs.store }

    static var enabledCategories: [ScanCategory] {
        ScanCategory.allCases.filter { isEnabled($0) }
    }

    static func isEnabled(_ category: ScanCategory) -> Bool {
        store.object(forKey: key(category)) as? Bool ?? true
    }

    static func key(_ category: ScanCategory) -> String { "scan.category.\(category.rawValue)" }
}

/// The last Smart Scan result, saved next to the database (S-052).
enum LastScan {
    struct Saved: Codable {
        var items: [ScanItem]
        var notScanned: [URL]
        var date: Date
    }

    static var url: URL { Store.url.deletingLastPathComponent().appending(path: Store.url.deletingPathExtension().lastPathComponent + "-last-scan.json") }

    static func save(items: [ScanItem], notScanned: [URL], date: Date) {
        let saved = Saved(items: items, notScanned: notScanned, date: date)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    static func load() -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }
}
