import Foundation

// MARK: - Browser data

/// What clearing a browser item does.
public enum BrowserDataKind: String, CaseIterable, Sendable {
    case cache, cookies, history

    public var title: String {
        switch self {
        case .cache: "Cache"
        case .cookies: "Cookies"
        case .history: "History"
        }
    }

    /// One line on what happens after clearing it.
    public var effect: String {
        switch self {
        case .cache: "Pages load a little slower the first time."
        case .cookies: "Signs you out of websites."
        case .history: "Removes the list of pages you visited."
        }
    }

    /// Only caches are ticked for you.
    public var isRecommended: Bool { self == .cache }
}

/// One browser item: a profile's cache, cookies, or history, which may be several files.
public struct BrowserItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(browser)|\(profile)|\(kind.rawValue)" }
    public let browser: String
    public let bundleID: String
    public let profile: String
    public let kind: BrowserDataKind
    public let urls: [URL]
    public let size: Int64

    public init(browser: String, bundleID: String, profile: String, kind: BrowserDataKind, urls: [URL], size: Int64) {
        self.browser = browser
        self.bundleID = bundleID
        self.profile = profile
        self.kind = kind
        self.urls = urls
        self.size = size
    }
}

public struct BrowserDataFinder: Sendable {
    public let home: URL
    public init(home: URL) { self.home = home }

    struct Chromium {
        let name: String
        let bundleID: String
        let support: String
        let caches: [String]
    }

    static let chromium: [Chromium] = [
        Chromium(name: "Google Chrome", bundleID: "com.google.Chrome", support: "Library/Application Support/Google/Chrome",
                 caches: ["Library/Caches/Google/Chrome", "Library/Caches/com.google.Chrome"]),
        Chromium(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", support: "Library/Application Support/Microsoft Edge",
                 caches: ["Library/Caches/Microsoft Edge", "Library/Caches/com.microsoft.edgemac"]),
        Chromium(name: "Brave", bundleID: "com.brave.Browser", support: "Library/Application Support/BraveSoftware/Brave-Browser",
                 caches: ["Library/Caches/BraveSoftware/Brave-Browser", "Library/Caches/com.brave.Browser"]),
        Chromium(name: "Arc", bundleID: "company.thebrowser.Browser", support: "Library/Application Support/Arc/User Data",
                 caches: ["Library/Caches/Arc", "Library/Caches/company.thebrowser.Browser"]),
    ]

    public static let browserBundleIDs: [String] = chromium.map(\.bundleID) + ["org.mozilla.firefox", "com.apple.Safari"]

    public func find() -> [BrowserItem] {
        var items: [BrowserItem] = []
        for c in Self.chromium { items += chromiumItems(c) }
        items += firefoxItems()
        items += safariItems()
        return items.filter { $0.size > 0 }
    }

    private func existing(_ paths: [URL]) -> [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0.path) && PathGuard.isAllowed($0, home: home) }
    }

    private func item(_ browser: String, _ id: String, _ profile: String, _ kind: BrowserDataKind, _ urls: [URL]) -> BrowserItem? {
        let found = existing(urls)
        guard !found.isEmpty else { return nil }
        return BrowserItem(browser: browser, bundleID: id, profile: profile, kind: kind, urls: found,
                           size: found.reduce(0) { $0 + Sizer.allocatedSize(of: $1) })
    }

    private func children(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// "Default", "Profile 1", and so on.
    static func isChromiumProfile(_ name: String) -> Bool {
        name == "Default" || name.hasPrefix("Profile ")
    }

    /// Browsers whose data folder exists but macOS won't let Steward read (it needs Full Disk Access).
    public func blockedBrowsers() -> [String] {
        var blocked: [String] = []
        for c in Self.chromium where isBlocked(home.appending(path: c.support)) { blocked.append(c.name) }
        if isBlocked(home.appending(path: "Library/Application Support/Firefox/Profiles")) { blocked.append("Firefox") }
        if isBlocked(home.appending(path: "Library/Safari")) { blocked.append("Safari") }
        return blocked
    }

    func isBlocked(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.path) && (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == nil
    }

    func chromiumItems(_ c: Chromium) -> [BrowserItem] {
        let support = home.appending(path: c.support)
        var items: [BrowserItem] = []
        // Profiles from the data folder, and from the cache folders, which stay readable
        // when macOS protects the data folder.
        var names = Set(children(support).filter(Self.isChromiumProfile))
        for root in c.caches { names.formUnion(children(home.appending(path: root)).filter(Self.isChromiumProfile)) }
        let profiles = names.sorted()
        for profile in profiles {
            let dir = support.appending(path: profile)
            let label = profile == "Default" ? "Default Profile" : profile
            var caches = [dir.appending(path: "Cache"), dir.appending(path: "Code Cache"), dir.appending(path: "GPUCache")]
            for root in c.caches { caches.append(home.appending(path: root).appending(path: profile)) }
            if let i = item(c.name, c.bundleID, label, .cache, caches) { items.append(i) }
            if let i = item(c.name, c.bundleID, label, .cookies, [dir.appending(path: "Cookies"), dir.appending(path: "Cookies-journal"),
                                                                  dir.appending(path: "Network/Cookies"), dir.appending(path: "Network/Cookies-journal")]) {
                items.append(i)
            }
            if let i = item(c.name, c.bundleID, label, .history, [dir.appending(path: "History"), dir.appending(path: "History-journal")]) {
                items.append(i)
            }
        }
        return items
    }

    /// Firefox keeps history and bookmarks in one file (places.sqlite), so history is never offered.
    func firefoxItems() -> [BrowserItem] {
        let profiles = home.appending(path: "Library/Application Support/Firefox/Profiles")
        let caches = home.appending(path: "Library/Caches/Firefox/Profiles")
        var items: [BrowserItem] = []
        for profile in children(profiles) where !profile.hasPrefix(".") {
            let label = profile.split(separator: ".").dropFirst().joined(separator: ".").nilIfEmpty ?? profile
            if let i = item("Firefox", "org.mozilla.firefox", label, .cache,
                            [caches.appending(path: profile).appending(path: "cache2"), caches.appending(path: profile).appending(path: "startupCache")]) {
                items.append(i)
            }
            let dir = profiles.appending(path: profile)
            if let i = item("Firefox", "org.mozilla.firefox", label, .cookies,
                            [dir.appending(path: "cookies.sqlite"), dir.appending(path: "cookies.sqlite-wal")]) {
                items.append(i)
            }
        }
        return items
    }

    /// Safari's history and cookies need Full Disk Access.
    func safariItems() -> [BrowserItem] {
        let lib = home.appending(path: "Library")
        var items: [BrowserItem] = []
        if let i = item("Safari", "com.apple.Safari", "Safari", .cache,
                        [lib.appending(path: "Caches/com.apple.Safari"),
                         lib.appending(path: "Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari")]) {
            items.append(i)
        }
        if let i = item("Safari", "com.apple.Safari", "Safari", .cookies,
                        [lib.appending(path: "Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                         lib.appending(path: "Cookies/Cookies.binarycookies")]) {
            items.append(i)
        }
        if let i = item("Safari", "com.apple.Safari", "Safari", .history,
                        [lib.appending(path: "Safari/History.db"), lib.appending(path: "Safari/History.db-wal"),
                         lib.appending(path: "Safari/History.db-shm")]) {
            items.append(i)
        }
        return items
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Recent items

/// One of macOS's recent-items lists.
public struct RecentList: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let title: String
    public let detail: String
    public let url: URL
    public let modified: Date?

    public init(title: String, detail: String, url: URL, modified: Date?) {
        self.title = title
        self.detail = detail
        self.url = url
        self.modified = modified
    }
}

public enum RecentItemsFinder {
    /// True when the lists' folder exists but macOS won't let Steward read it.
    public static func isBlocked(home: URL) -> Bool {
        let dir = home.appending(path: "Library/Application Support/com.apple.sharedfilelist")
        return FileManager.default.fileExists(atPath: dir.path) && (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == nil
    }

    static let lists: [(name: String, title: String, detail: String)] = [
        ("com.apple.LSSharedFileList.RecentDocuments", "Recent Documents", "Documents in the Apple menu's Recent Items"),
        ("com.apple.LSSharedFileList.RecentApplications", "Recent Apps", "Apps in the Apple menu's Recent Items"),
        ("com.apple.LSSharedFileList.RecentServers", "Recent Servers", "Servers in Finder's Connect to Server"),
        ("com.apple.LSSharedFileList.RecentHosts", "Recent Hosts", "Computers you connected to"),
    ]

    public static func find(home: URL) -> [RecentList] {
        let fm = FileManager.default
        let base = home.appending(path: "Library/Application Support/com.apple.sharedfilelist")
        func modified(_ u: URL) -> Date? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        var result: [RecentList] = []
        for list in lists {
            for ext in ["sfl3", "sfl2"] {
                let url = base.appending(path: "\(list.name).\(ext)")
                if fm.fileExists(atPath: url.path) {
                    result.append(RecentList(title: list.title, detail: list.detail, url: url, modified: modified(url)))
                    break
                }
            }
        }
        let perApp = base.appending(path: "com.apple.LSSharedFileList.ApplicationRecentDocuments")
        for name in ((try? fm.contentsOfDirectory(atPath: perApp.path)) ?? []).sorted()
        where name.hasSuffix(".sfl3") || name.hasSuffix(".sfl2") {
            let id = String(name.dropLast(5))
            let url = perApp.appending(path: name)
            result.append(RecentList(title: "Recent Documents in \(id)", detail: "The app's File > Open Recent menu", url: url, modified: modified(url)))
        }
        return result.filter { PathGuard.isAllowed($0.url, home: home) }
    }
}

// MARK: - Background jobs

/// One line of `launchctl list`.
public struct LaunchJob: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public let label: String
    public let pid: Int32?
    public let lastExitStatus: Int

    public init(label: String, pid: Int32?, lastExitStatus: Int) {
        self.label = label
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    public var isRunning: Bool { pid != nil }
    public var isApple: Bool { label.hasPrefix("com.apple.") || label.hasPrefix("application.com.apple.") }

    /// Parses `launchctl list`: a header, then "PID<tab>Status<tab>Label" with "-" for no PID.
    public static func parse(_ output: String) -> [LaunchJob] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return nil }
            let label = String(cols[2]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }
            return LaunchJob(label: label, pid: Int32(cols[0]), lastExitStatus: Int(cols[1]) ?? 0)
        }
    }

    /// Jobs in this user's domain. Read-only.
    public static func list() -> [LaunchJob] {
        guard let result = try? ProcessRunner.run("/bin/launchctl", ["list"]) else { return [] }
        return parse(result.output)
    }

    /// The app a job belongs to: "application.<bundle id>.<n>" jobs name it directly.
    public var applicationBundleID: String? {
        guard label.hasPrefix("application.") else { return nil }
        var parts = label.dropFirst("application.".count).split(separator: ".")
        if let last = parts.last, Int(last) != nil { parts.removeLast() }
        return parts.joined(separator: ".")
    }
}
