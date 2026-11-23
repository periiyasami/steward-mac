import AppKit
import Foundation
import Observation
import StewardKit

/// Browser caches, cookies, and history, cleared through Review.
@Observable
final class BrowserDataModel {
    let home: URL
    var items: [BrowserItem] = []
    var ticked: Set<String> = []
    /// Browsers Steward can't fully read without Full Disk Access.
    var blocked: [String] = []
    var loading = false
    var hasLoaded = false
    /// Shown when a browser must quit first.
    var message: String?
    /// Bundle ids of running browsers. Injectable for tests.
    var runningBundleIDs: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    init(home: URL) { self.home = home }

    var browsers: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.browser) { seen.append(i.browser) }
        return seen
    }

    func items(for browser: String) -> [BrowserItem] { items.filter { $0.browser == browser } }
    var tickedItems: [BrowserItem] { items.filter { ticked.contains($0.id) } }

    func isRunning(_ browser: String) -> Bool {
        guard let id = items.first(where: { $0.browser == browser })?.bundleID else { return false }
        return runningBundleIDs().contains(id)
    }

    func load() {
        loading = true
        hasLoaded = true
        let finder = BrowserDataFinder(home: home)
        Task {
            let (found, blockedNow) = await Task.detached { (finder.find(), finder.blockedBrowsers()) }.value
            items = found
            blocked = blockedNow
            ticked = Set(found.filter { Prefs.ticksByDefault($0.kind) }.map(\.id))
            loading = false
        }
    }

    func toggle(_ item: BrowserItem) {
        if ticked.contains(item.id) { ticked.remove(item.id) } else { ticked.insert(item.id) }
    }

    /// Asks a browser to quit. Never forces it.
    func quit(_ browser: String) {
        guard let id = items.first(where: { $0.browser == browser })?.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    /// nil when nothing is ticked or a ticked browser is still open.
    func reviewSession() -> ReviewSession? {
        message = nil
        let chosen = tickedItems
        guard !chosen.isEmpty else { return nil }
        let open = Set(chosen.map(\.browser)).filter { isRunning($0) }.sorted()
        guard open.isEmpty else {
            message = "Quit \(open.joined(separator: " and ")) first, so it can't write the files back."
            return nil
        }
        let rows = chosen.flatMap { item in
            item.urls.map { url in
                Candidate(url: url, size: Sizer.allocatedSize(of: url),
                          reason: "\(item.browser), \(item.profile), \(item.kind.title.lowercased()): \(item.kind.effect)",
                          group: "Browser Data")
            }
        }
        return ReviewSession(source: .browserData, rows: rows)
    }

    func removed(_ paths: Set<String>) {
        items.removeAll { item in item.urls.allSatisfy { paths.contains($0.path) } }
        ticked = ticked.filter { id in items.contains { $0.id == id } }
    }

    func loadSample() {
        let lib = home.appending(path: "Library")
        func i(_ b: String, _ id: String, _ p: String, _ k: BrowserDataKind, _ s: Int64) -> BrowserItem {
            BrowserItem(browser: b, bundleID: id, profile: p, kind: k, urls: [lib.appending(path: "\(b)/\(p)/\(k.rawValue)")], size: s)
        }
        items = [i("Google Chrome", "com.google.Chrome", "Default Profile", .cache, 1_240_000_000),
                 i("Google Chrome", "com.google.Chrome", "Default Profile", .cookies, 4_200_000),
                 i("Google Chrome", "com.google.Chrome", "Default Profile", .history, 38_000_000),
                 i("Google Chrome", "com.google.Chrome", "Profile 1", .cache, 310_000_000),
                 i("Safari", "com.apple.Safari", "Safari", .cache, 420_000_000),
                 i("Safari", "com.apple.Safari", "Safari", .history, 12_000_000),
                 i("Firefox", "org.mozilla.firefox", "default-release", .cache, 220_000_000),
                 i("Firefox", "org.mozilla.firefox", "default-release", .cookies, 1_800_000)]
        ticked = Set(items.filter(\.kind.isRecommended).map(\.id))
        runningBundleIDs = { ["com.google.Chrome"] }
        hasLoaded = true
        loading = false
    }
}

/// macOS's recent-items lists, cleared through Review.
@Observable
final class RecentItemsModel {
    let home: URL
    var lists: [RecentList] = []
    var ticked: Set<String> = []
    var hasLoaded = false
    var isBlocked = false
    var message: String?
    /// Runs `qlmanage -r cache`. Injectable so tests never touch the real cache.
    let resetQuickLook: @Sendable () -> Bool

    init(home: URL, resetQuickLook: @escaping @Sendable () -> Bool) {
        self.home = home
        self.resetQuickLook = resetQuickLook
    }

    static let realQuickLookReset: @Sendable () -> Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-r", "cache"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func load() {
        hasLoaded = true
        lists = RecentItemsFinder.find(home: home)
        isBlocked = RecentItemsFinder.isBlocked(home: home)
        ticked = Set(lists.map(\.id))
    }

    func reviewSession() -> ReviewSession? {
        let rows = lists.filter { ticked.contains($0.id) }.map {
            Candidate(url: $0.url, size: Sizer.allocatedSize(of: $0.url), reason: "\($0.title): \($0.detail)", group: "Recent Items")
        }
        return rows.isEmpty ? nil : ReviewSession(source: .recentItems, rows: rows)
    }

    func runQuickLookReset() async {
        let run = resetQuickLook
        let ok = await Task.detached { run() }.value
        message = ok ? "Quick Look thumbnails were reset. They come back as you browse." : "Couldn't reset Quick Look thumbnails."
    }

    func removed(_ paths: Set<String>) {
        lists.removeAll { paths.contains($0.id) }
        ticked.subtract(paths)
    }

    func loadSample() {
        let base = home.appending(path: "Library/Application Support/com.apple.sharedfilelist")
        lists = [RecentList(title: "Recent Documents", detail: "Documents in the Apple menu's Recent Items", url: base.appending(path: "a.sfl3"), modified: .now),
                 RecentList(title: "Recent Apps", detail: "Apps in the Apple menu's Recent Items", url: base.appending(path: "b.sfl3"), modified: .now),
                 RecentList(title: "Recent Servers", detail: "Servers in Finder's Connect to Server", url: base.appending(path: "c.sfl3"), modified: Date.now.addingTimeInterval(-86_400 * 30)),
                 RecentList(title: "Recent Documents in com.apple.TextEdit", detail: "The app's File > Open Recent menu", url: base.appending(path: "d.sfl3"), modified: Date.now.addingTimeInterval(-3_600))]
        ticked = Set(lists.map(\.id))
        hasLoaded = true
        message = nil
    }
}
