import AppKit
import Foundation
import Observation
import StewardKit

// MARK: - Unused Apps

enum UnusedPeriod: Int, CaseIterable, Identifiable {
    case three = 3, six = 6, twelve = 12
    var id: Int { rawValue }
    var title: String { "Not Opened in \(rawValue) Months" }
    func cutoff(now: Date = .now) -> Date { Calendar.current.date(byAdding: .month, value: -rawValue, to: now) ?? now }
}

extension UninstallerModel {
    /// Apps that can be removed and have not been opened in the period, biggest first.
    func unused(_ period: UnusedPeriod, now: Date = .now) -> [AppRow] {
        let cutoff = period.cutoff(now: now)
        return rows
            .filter { !$0.app.isLocked && UnusedRule.isUnused(lastUsed: $0.lastUsed, added: $0.added, cutoff: cutoff) }
            .sorted { ($0.total ?? 0) > ($1.total ?? 0) }
    }
}

// MARK: - Permissions

/// Which apps have privacy permissions, read from the TCC databases.
@Observable
final class PermissionsModel {
    struct Row: Identifiable, Hashable {
        var id: String { grant.id }
        let grant: PermissionGrant
        let name: String
        let appURL: URL?
    }

    let databases: [URL]
    var rows: [Row] = []
    var loading = false
    var hasLoaded = false
    /// No database could be read: Steward needs Full Disk Access.
    var isLocked = false

    init(databases: [URL]) { self.databases = databases }

    var services: [PrivacyService] {
        PrivacyService.allCases.filter { s in rows.contains { $0.grant.service == s } }
    }

    func rows(for service: PrivacyService) -> [Row] {
        rows.filter { $0.grant.service == service }
            .sorted { ($0.grant.allowed ? 0 : 1, $0.name.lowercased()) < ($1.grant.allowed ? 0 : 1, $1.name.lowercased()) }
    }

    func load() {
        loading = true
        hasLoaded = true
        let dbs = databases
        Task {
            let (grants, readAny) = await Task.detached { () -> ([PermissionGrant], Bool) in
                var all: [PermissionGrant] = []
                var ok = false
                for db in dbs {
                    if let g = try? TCCReader.read(db) { all += g; ok = true }
                }
                return (all, ok)
            }.value
            isLocked = !readAny
            // One row per service and client, the user's database first.
            var seen = Set<String>()
            rows = grants.filter { seen.insert($0.id).inserted }.map(Self.row)
            loading = false
        }
    }

    static func row(_ g: PermissionGrant) -> Row {
        if g.isPath {
            let url = URL(fileURLWithPath: g.client)
            return Row(grant: g, name: url.lastPathComponent, appURL: nil)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: g.client)
        let name = url.map { $0.deletingPathExtension().lastPathComponent } ?? g.client
        return Row(grant: g, name: name, appURL: url)
    }

    static func openSettings(for service: PrivacyService) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(service.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func loadSample() {
        func r(_ s: PrivacyService, _ name: String, _ allowed: Bool) -> Row {
            Row(grant: PermissionGrant(service: s, client: "com.example.\(name.lowercased())", isPath: false, allowed: allowed, lastModified: nil),
                name: name, appURL: nil)
        }
        rows = [r(.camera, "Zoom", true), r(.camera, "Slack", true), r(.camera, "Figma", false),
                r(.microphone, "Zoom", true), r(.microphone, "Slack", true), r(.microphone, "Discord", false),
                r(.screenCapture, "Zoom", true), r(.screenCapture, "CleanShot X", true), r(.screenCapture, "Terminal", true),
                r(.accessibility, "Raycast", true), r(.accessibility, "Rectangle", true),
                r(.fullDisk, "Terminal", true), r(.fullDisk, "Steward", true), r(.automation, "Raycast", true)]
        isLocked = false
        loading = false
        hasLoaded = true
    }
}

// MARK: - Updates

/// Version checks for apps outside the App Store. Only runs when asked and allowed.
@Observable
final class UpdatesModel {
    enum State: Hashable {
        case notChecked, checking, upToDate, available(String), failed(String), appStore, noFeed
    }

    struct Row: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let name: String
        let current: String?
        let kind: UpdateSource.Kind
        var state: State

        var isCheckable: Bool { kind.isCheckable }
        /// The Homebrew command that updates it, for casks.
        var brewCommand: String? {
            if case .homebrew(let token, let installed) = kind { return CaskInfo(token: token, version: installed).upgradeCommand }
            return nil
        }
    }

    var rows: [Row] = []
    var checking = false
    var lastChecked: Date?
    var hasLoaded = false
    /// Where Homebrew keeps installed casks. The self-test points it at a fixture.
    var caskrooms = HomebrewCasks.defaultCaskrooms
    /// Said after Copy Command.
    var message: String?

    static var allowed: Bool { Prefs.updatesAllowed }

    var available: [Row] { rows.filter { if case .available = $0.state { true } else { false } } }
    var checkable: [Row] { rows.filter(\.isCheckable) }
    var others: [Row] { rows.filter { !$0.isCheckable } }
    /// Homebrew commands for every cask with an update.
    var brewUpgrades: [String] { available.compactMap(\.brewCommand) }

    /// Reads each app's Info.plist, updater files, and Homebrew's Caskroom. No network.
    func load(apps: [InstalledApp]) {
        hasLoaded = true
        let casks = HomebrewCasks.index(caskrooms: caskrooms)
        let found = apps.map { app -> Row in
            let source = UpdateSource.of(app: app.url, casks: casks)
            let state: State = switch source.kind {
            case .appStore: .appStore
            case .unknown: .noFeed
            default: .notChecked
            }
            return Row(url: app.url, name: app.name, current: source.currentVersion, kind: source.kind, state: state)
        }
        rows = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Fetches each source. Never runs unless the person allowed update checks.
    func checkAll(allowed: Bool = UpdatesModel.allowed) async {
        guard allowed, !checking else { return }
        checking = true
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .never
        config.httpAdditionalHeaders = ["User-Agent": "Steward"]
        let session = URLSession(configuration: config)
        for i in rows.indices where rows[i].isCheckable {
            rows[i].state = .checking
        }
        await withTaskGroup(of: (String, State).self) { group in
            for row in rows where row.isCheckable {
                let kind = row.kind, current = kind.installedVersion ?? row.current ?? "0", id = row.id
                group.addTask {
                    guard let url = kind.requestURL, ["https", "file"].contains(url.scheme ?? "") else {
                        return (id, .failed("No update address"))
                    }
                    do {
                        let (data, response) = try await session.data(from: url)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            return (id, .failed("The update server answered \(http.statusCode)"))
                        }
                        guard let newest = kind.newestVersion(in: data) else { return (id, .failed("No versions in the feed")) }
                        return (id, Version.isNewer(newest, than: current) ? .available(newest) : .upToDate)
                    } catch {
                        return (id, .failed("Couldn't reach the update server"))
                    }
                }
            }
            for await (id, state) in group {
                if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].state = state }
            }
        }
        lastChecked = .now
        checking = false
    }

    /// Puts Homebrew commands on the clipboard, to paste into Terminal.
    func copy(_ commands: [String]) {
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.joined(separator: " && "), forType: .string)
        message = commands.count == 1 ? "Copied. Paste it into Terminal." : "Copied \(commands.count) commands. Paste them into Terminal."
    }

    func loadSample() {
        let base = URL(fileURLWithPath: "/Applications")
        func r(_ n: String, _ v: String, _ s: State, _ kind: UpdateSource.Kind? = nil) -> Row {
            Row(url: base.appending(path: "\(n).app"), name: n, current: v,
                kind: kind ?? .sparkle(URL(string: "https://example.com/\(n).xml")!), state: s)
        }
        rows = [r("Figma", "125.3.2", .available("125.4.1"), .electron(URL(string: "https://example.com/figma")!)),
                r("iTerm", "3.5.4", .available("3.5.10")),
                r("Visual Studio Code", "1.95.3", .available("1.96.0"), .homebrew(token: "visual-studio-code", installed: "1.95.3")),
                r("Rectangle", "0.84", .upToDate), r("VLC", "3.0.20", .failed("Couldn't reach the update server")),
                r("Obsidian", "1.7.7", .upToDate, .github(owner: "obsidianmd", repo: "obsidian-releases")),
                r("Keynote", "14.4", .appStore, .appStore), r("Slack", "4.41.105", .noFeed, .unknown)]
        lastChecked = Date.now.addingTimeInterval(-600)
        hasLoaded = true
        checking = false
    }
}
