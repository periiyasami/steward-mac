import AppKit
import Foundation
import Observation
import StewardKit

/// State for the Uninstaller: installed apps with sizes, the selected app's
/// leftovers, and leftovers of apps that are gone.
@Observable
final class UninstallerModel {
    enum Mode: String, CaseIterable { case apps, leftovers }

    struct AppRow: Identifiable, Hashable {
        var id: String { app.id }
        let app: InstalledApp
        var bundleSize: Int64?
        var leftoverSize: Int64?
        var lastUsed: Date?
        /// When the app arrived on this Mac.
        var added: Date?
        var total: Int64? { bundleSize.map { $0 + (leftoverSize ?? 0) } }
    }

    let home: URL
    let folders: [URL]
    var mode: Mode = .apps
    var rows: [AppRow] = []
    var loading = false
    var hasLoaded = false
    var search = ""
    var selection: String? {
        didSet { if selection != oldValue { loadLeftovers() } }
    }
    var leftovers: [Leftover] = []
    var leftoverTicks: Set<String> = []
    var loadingLeftovers = false
    /// Shown under the app when Uninstall cannot go ahead.
    var message: String?
    var quitting = false

    var orphans: [Leftover] = []
    var orphanTicks: Set<String> = []
    var loadingOrphans = false
    var hasLoadedOrphans = false
    var orphanSelection: Set<String> = []

    private var loadTask: Task<Void, Never>?
    private var leftoverTask: Task<Void, Never>?

    init(home: URL, folders: [URL]) {
        self.home = home
        self.folders = folders
    }

    var filtered: [AppRow] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.app.name.localizedCaseInsensitiveContains(q) || ($0.app.bundleID ?? "").localizedCaseInsensitiveContains(q) }
    }

    var selected: AppRow? { rows.first { $0.id == selection } }

    // MARK: Apps

    func load() {
        loadTask?.cancel()
        loading = true
        hasLoaded = true
        let folders = folders, home = home
        loadTask = Task {
            let apps = await Task.detached { AppCatalog.installedApps(in: folders, home: home) }.value
            rows = apps.map { AppRow(app: $0) }
            loading = false
            if selection == nil { selection = rows.first { !$0.app.isLocked }?.id }
            // Sizes and last used dates, one app at a time.
            let finder = LeftoverFinder(home: home)
            for app in apps {
                if Task.isCancelled { break }
                let (bundle, extra, used, added) = await Task.detached {
                    (Sizer.allocatedSize(of: app.url),
                     finder.leftovers(for: app).reduce(Int64(0)) { $0 + $1.size },
                     LargeFileFinder.lastUsedDate(app.url),
                     (try? app.url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])).flatMap { $0.addedToDirectoryDate ?? $0.creationDate })
                }.value
                if let i = rows.firstIndex(where: { $0.id == app.id }) {
                    rows[i].bundleSize = bundle
                    rows[i].leftoverSize = extra
                    rows[i].lastUsed = used
                    rows[i].added = added
                }
            }
        }
    }

    func loadLeftovers() {
        leftoverTask?.cancel()
        message = nil
        guard let app = selected?.app else { leftovers = []; return }
        loadingLeftovers = true
        let finder = LeftoverFinder(home: home)
        leftoverTask = Task {
            let found = await Task.detached { finder.leftovers(for: app) }.value
            guard !Task.isCancelled else { return }
            leftovers = found
            leftoverTicks = Set(found.filter(\.isCertain).map(\.id))
            loadingLeftovers = false
        }
    }

    var leftoverLocations: [String] {
        var seen: [String] = []
        for l in leftovers where !seen.contains(l.location) { seen.append(l.location) }
        return seen
    }

    func toggleLeftover(_ l: Leftover) {
        if leftoverTicks.contains(l.id) { leftoverTicks.remove(l.id) } else { leftoverTicks.insert(l.id) }
    }

    var canUninstall: Bool { selected.map { !$0.app.isLocked } ?? false && !quitting }

    /// Asks a running app to quit (never forces it), then opens Review with
    /// the app and its ticked leftovers.
    func uninstallSession() async -> ReviewSession? {
        guard let row = selected, !row.app.isLocked else { return nil }
        let app = row.app
        message = nil
        if let id = app.bundleID {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if !running.isEmpty {
                quitting = true
                running.forEach { $0.terminate() }
                for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                quitting = false
                if running.contains(where: { !$0.isTerminated }) {
                    message = "\(app.name) is still open. Quit it, then try again."
                    return nil
                }
            }
        }
        var rows = [Candidate(url: app.url, size: row.bundleSize ?? Sizer.allocatedSize(of: app.url),
                              reason: "The app", group: "App", isAppBundle: true)]
        rows += leftovers.map {
            Candidate(url: $0.url, size: $0.size,
                      reason: $0.isCertain ? "\(app.name) leftover in \($0.location)" : "Possible match in \($0.location)",
                      group: "App Leftovers", ticked: leftoverTicks.contains($0.id))
        }
        return ReviewSession(source: .uninstaller, rows: rows, title: "Uninstall \(app.name)")
    }

    // MARK: Leftovers of removed apps

    func loadOrphans() {
        loadingOrphans = true
        hasLoadedOrphans = true
        let installed = Set(rows.compactMap(\.app.bundleID))
        let finder = LeftoverFinder(home: home)
        let checkLaunchServices = !Store.isOverridden
        Task {
            let found = await Task.detached {
                finder.orphans { id in
                    LeftoverFinder.isOwned(id, by: installed) || (checkLaunchServices && AppCatalog.isRegistered(id))
                }
            }.value
            orphans = found
            orphanTicks = []
            loadingOrphans = false
        }
    }

    /// Bundle ids with their leftovers, biggest first.
    var orphanGroups: [(owner: String, items: [Leftover])] {
        Dictionary(grouping: orphans) { $0.owner ?? "" }
            .map { (owner: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }
    }

    var tickedOrphans: [Leftover] { orphans.filter { orphanTicks.contains($0.id) } }

    func orphanSession() -> ReviewSession? {
        let rows = tickedOrphans.map {
            Candidate(url: $0.url, size: $0.size, reason: "No installed app uses \($0.owner ?? "this")",
                      group: "Leftovers")
        }
        return rows.isEmpty ? nil : ReviewSession(source: .leftovers, rows: rows)
    }

    // MARK: After a clean

    func removed(_ paths: Set<String>) {
        rows.removeAll { paths.contains($0.id) }
        leftovers.removeAll { paths.contains($0.id) }
        orphans.removeAll { paths.contains($0.id) }
        leftoverTicks.subtract(paths)
        orphanTicks.subtract(paths)
        if let s = selection, paths.contains(s) { selection = rows.first { !$0.app.isLocked }?.id }
    }

    func restored() {
        if hasLoaded, !Store.isOverridden { load() }
        if hasLoadedOrphans, !Store.isOverridden { loadOrphans() }
    }

    // MARK: Snapshot sample

    func loadSample() {
        loadTask?.cancel()
        leftoverTask?.cancel()
        let base = URL(fileURLWithPath: "/Applications")
        let samples: [(String, String, String, Int64, Int64, Int, Bool)] = [
            ("Figma", "com.figma.Desktop", "125.3.2", 512_000_000, 1_840_000_000, -2, false),
            ("Keynote", "com.apple.iWork.Keynote", "14.4", 724_000_000, 0, -40, true),
            ("Slack", "com.tinyspeck.slackmacgap", "4.41.105", 486_000_000, 2_310_000_000, -1, false),
            ("Spotify", "com.spotify.client", "1.2.52", 398_000_000, 4_120_000_000, -6, false),
            ("Visual Studio Code", "com.microsoft.VSCode", "1.95.3", 612_000_000, 980_000_000, -14, false),
            ("Zoom", "us.zoom.xos", "6.2.11", 286_000_000, 410_000_000, -210, false),
        ]
        rows = samples.map { name, id, version, bundle, extra, days, locked in
            AppRow(app: InstalledApp(url: base.appending(path: "\(name).app"), name: name, bundleID: id, version: version,
                                     teamID: nil, isLocked: locked),
                   bundleSize: bundle, leftoverSize: extra, lastUsed: Calendar.current.date(byAdding: .day, value: days, to: .now))
        }
        hasLoaded = true
        loading = false
        let lib = home.appending(path: "Library")
        selection = rows[2].id
        leftoverTask?.cancel()
        leftovers = [
            Leftover(url: lib.appending(path: "Application Support/Slack"), size: 1_720_000_000, location: "Application Support", isCertain: false),
            Leftover(url: lib.appending(path: "Caches/com.tinyspeck.slackmacgap"), size: 412_000_000, location: "Caches", isCertain: true),
            Leftover(url: lib.appending(path: "Containers/com.tinyspeck.slackmacgap"), size: 96_000_000, location: "Containers", isCertain: true),
            Leftover(url: lib.appending(path: "HTTPStorages/com.tinyspeck.slackmacgap"), size: 2_400_000, location: "HTTPStorages", isCertain: true),
            Leftover(url: lib.appending(path: "Preferences/com.tinyspeck.slackmacgap.plist"), size: 12_000, location: "Preferences", isCertain: true),
            Leftover(url: lib.appending(path: "Saved Application State/com.tinyspeck.slackmacgap.savedState"), size: 48_000, location: "Saved Application State", isCertain: true),
        ]
        leftoverTicks = Set(leftovers.filter(\.isCertain).map(\.id))
        loadingLeftovers = false
        orphans = [
            Leftover(url: lib.appending(path: "Containers/com.readdle.smartemail-Mac"), size: 2_840_000_000, location: "Containers", isCertain: false, owner: "com.readdle.smartemail-Mac"),
            Leftover(url: lib.appending(path: "Preferences/com.readdle.smartemail-Mac.plist"), size: 24_000, location: "Preferences", isCertain: false, owner: "com.readdle.smartemail-Mac"),
            Leftover(url: lib.appending(path: "Application Support/com.bohemiancoding.sketch3"), size: 640_000_000, location: "Application Support", isCertain: false, owner: "com.bohemiancoding.sketch3"),
            Leftover(url: lib.appending(path: "Caches/com.bohemiancoding.sketch3"), size: 210_000_000, location: "Caches", isCertain: false, owner: "com.bohemiancoding.sketch3"),
            Leftover(url: lib.appending(path: "Saved Application State/org.videolan.vlc.savedState"), size: 36_000, location: "Saved Application State", isCertain: false, owner: "org.videolan.vlc"),
        ]
        orphanTicks = [orphans[0].id, orphans[1].id]
        hasLoadedOrphans = true
        loadingOrphans = false
    }
}
