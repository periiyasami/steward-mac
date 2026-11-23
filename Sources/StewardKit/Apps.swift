import CoreServices
import Foundation
import Security

/// An app in /Applications or ~/Applications.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let teamID: String?
    /// Apple's own apps, and apps the user cannot move.
    public let isLocked: Bool

    public init(url: URL, name: String, bundleID: String?, version: String?, teamID: String?, isLocked: Bool) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.isLocked = isLocked
    }
}

/// A file an app keeps outside its bundle.
public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    /// Where it lives, like "Application Support" or "Preferences".
    public let location: String
    /// Matched by bundle id. False for name-only or team-only matches ("Possible match").
    public let isCertain: Bool
    /// The bundle id it belongs to, for leftovers of removed apps.
    public let owner: String?

    public init(url: URL, size: Int64, location: String, isCertain: Bool, owner: String? = nil) {
        self.url = url
        self.size = size
        self.location = location
        self.isCertain = isCertain
        self.owner = owner
    }
}

public enum AppCatalog {
    public static func defaultFolders(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
    }

    /// Apps directly in each folder, and one folder below (like /Applications/Vendor/Tool.app).
    public static func installedApps(in folders: [URL], home: URL) -> [InstalledApp] {
        let fm = FileManager.default
        var urls: [URL] = []
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                let url = folder.appending(path: name)
                if url.pathExtension == "app" {
                    urls.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for inner in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        urls.append(url.appending(path: inner))
                    }
                }
            }
        }
        return urls.map { app(at: $0, home: home, folders: folders) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func app(at url: URL, home: URL, folders: [URL]? = nil) -> InstalledApp {
        let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        // The Finder name, which is what people see and what leftover folders usually use.
        let name = url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let removable = AppGuard.isRemovableApp(url, home: home, applications: folders)
            && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
        return InstalledApp(url: url, name: name, bundleID: bundleID, version: version, teamID: teamID(of: url), isLocked: !removable)
    }

    /// The developer's team id from the code signature, if signed.
    public static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether any app with this bundle id is known to Launch Services.
    public static func isRegistered(_ bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return false
        }
        return !urls.isEmpty
    }
}

/// Finds an app's leftovers in ~/Library, and leftovers of apps that are gone.
public struct LeftoverFinder: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    enum Match { case exact, prefix, suffix(String) }

    /// Folder in ~/Library, its title, and how entries are named after a bundle id.
    static let locations: [(folder: String, title: String, match: Match)] = [
        ("Application Support", "Application Support", .exact),
        ("Caches", "Caches", .exact),
        ("Preferences", "Preferences", .suffix(".plist")),
        ("Preferences/ByHost", "Preferences", .prefix),
        ("Containers", "Containers", .exact),
        ("Saved Application State", "Saved Application State", .suffix(".savedState")),
        ("HTTPStorages", "HTTPStorages", .exact),
        ("HTTPStorages", "HTTPStorages", .suffix(".binarycookies")),
        ("WebKit", "WebKit", .exact),
        ("Logs", "Logs", .exact),
        ("LaunchAgents", "LaunchAgents", .prefix),
        ("Application Scripts", "Application Scripts", .exact),
    ]

    /// Folders where an app's own name (not its bundle id) is a possible match.
    static let nameLocations: [(folder: String, title: String)] = [
        ("Application Support", "Application Support"), ("Caches", "Caches"), ("Logs", "Logs"),
    ]

    public func leftovers(for app: InstalledApp) -> [Leftover] {
        let fm = FileManager.default
        let library = home.appending(path: "Library")
        var found: [String: Leftover] = [:]
        func add(_ url: URL, _ title: String, certain: Bool) {
            guard PathGuard.isAllowed(url, home: home), fm.fileExists(atPath: url.path) else { return }
            if let existing = found[url.path], existing.isCertain || !certain { return }
            found[url.path] = Leftover(url: url, size: Sizer.allocatedSize(of: url), location: title, isCertain: certain,
                                       owner: app.bundleID)
        }
        if let id = app.bundleID, !id.isEmpty {
            for loc in Self.locations {
                let dir = library.appending(path: loc.folder)
                switch loc.match {
                case .exact: add(dir.appending(path: id), loc.title, certain: true)
                case .suffix(let s): add(dir.appending(path: id + s), loc.title, certain: true)
                case .prefix:
                    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(id + ".") || name == id {
                        add(dir.appending(path: name), loc.title, certain: true)
                    }
                }
            }
            let groups = library.appending(path: "Group Containers")
            for name in (try? fm.contentsOfDirectory(atPath: groups.path)) ?? [] {
                if name.contains(id) {
                    add(groups.appending(path: name), "Group Containers", certain: true)
                } else if let team = app.teamID, name.hasPrefix(team + ".") {
                    add(groups.appending(path: name), "Group Containers", certain: false)
                }
            }
        }
        // The app's name, only when it is distinctive enough.
        let name = app.name
        if name.count >= 4 {
            for loc in Self.nameLocations {
                let dir = library.appending(path: loc.folder)
                for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where entry.caseInsensitiveCompare(name) == .orderedSame {
                    add(dir.appending(path: entry), loc.title, certain: false)
                }
            }
        }
        return found.values.sorted { ($0.location, $1.size) < ($1.location, $0.size) }
    }

    /// Files named after a bundle id that no installed app has. Apple's ids
    /// are never listed. `isInstalled` decides whether an id still has an app.
    public func orphans(isInstalled: (String) -> Bool) -> [Leftover] {
        let fm = FileManager.default
        let library = home.appending(path: "Library")
        let folders: [(String, String, String)] = [
            ("Containers", "Containers", ""), ("Application Support", "Application Support", ""),
            ("Caches", "Caches", ""), ("Preferences", "Preferences", ".plist"),
            ("Saved Application State", "Saved Application State", ".savedState"),
            ("HTTPStorages", "HTTPStorages", ""), ("WebKit", "WebKit", ""), ("Application Scripts", "Application Scripts", ""),
        ]
        var result: [Leftover] = []
        for (folder, title, suffix) in folders {
            let dir = library.appending(path: folder)
            for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                var id = entry
                if !suffix.isEmpty {
                    guard entry.hasSuffix(suffix) else { continue }
                    id = String(entry.dropLast(suffix.count))
                }
                guard Self.looksLikeBundleID(id), !Self.isApple(id), !isInstalled(id) else { continue }
                let url = dir.appending(path: entry)
                guard PathGuard.isAllowed(url, home: home) else { continue }
                let size = Sizer.allocatedSize(of: url)
                guard size > 0 else { continue }
                result.append(Leftover(url: url, size: size, location: title, isCertain: false, owner: id))
            }
        }
        return result
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    static func isApple(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.")
    }

    /// An id belongs to an installed app when it is that app's id, or a helper of it (com.vendor.app.helper).
    public static func isOwned(_ id: String, by installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        return installed.contains { let i = $0.lowercased(); return lower == i || lower.hasPrefix(i + ".") }
    }
}

/// When an app counts as unused.
public enum UnusedRule {
    /// Unused when last opened before the cutoff. With no last-opened date,
    /// only when it was added before the cutoff (a new app has had no chance yet).
    public static func isUnused(lastUsed: Date?, added: Date?, cutoff: Date) -> Bool {
        if let lastUsed { return lastUsed < cutoff }
        if let added { return added < cutoff }
        return false
    }
}
