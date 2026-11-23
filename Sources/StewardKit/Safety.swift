import Foundation

/// The rule every scan and every removal goes through: only items strictly
/// inside the home folder, never the home folder or its top folders
/// themselves. Paths are compared without resolving symlinks, so moving a
/// symlink to the Trash moves the link, never its target.
public enum PathGuard {
    /// Folders that hold items but are never items themselves.
    static let protectedFolders: Set<String> = [
        "", "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
        "Library/Preferences", "Library/Containers", "Library/Group Containers",
        "Library/Developer", "Library/Developer/Xcode", "Library/Developer/Xcode/DerivedData",
        "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Caches",
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
    ]

    public static func isAllowed(_ url: URL, home: URL) -> Bool {
        guard let relative = relativePath(of: url, in: home) else { return false }
        if protectedFolders.contains(relative) { return false }
        if relative.split(separator: "/").contains("..") { return false }
        return true
    }

    /// The path of `url` relative to `home`, or nil when it is outside.
    public static func relativePath(of url: URL, in home: URL) -> String? {
        let base = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

/// App bundles are the one thing outside the home folder Steward may move:
/// a .app directly in /Applications, ~/Applications, or one folder below
/// them, that is not Apple's own.
public enum AppGuard {
    public static func isRemovableApp(_ url: URL, home: URL, applications: [URL]? = nil) -> Bool {
        let path = url.standardizedFileURL
        guard path.pathExtension == "app" else { return false }
        let roots = (applications ?? [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")])
            .map { $0.standardizedFileURL.path }
        let parent = path.deletingLastPathComponent().path
        let grandparent = path.deletingLastPathComponent().deletingLastPathComponent().path
        guard roots.contains(parent) || roots.contains(grandparent) else { return false }
        if let id = Bundle(url: path)?.bundleIdentifier, id.hasPrefix("com.apple.") { return false }
        return true
    }
}

/// Skipped Items: paths Steward never chooses.
public struct SkipList: Sendable, Hashable {
    public var paths: Set<String>

    public init(_ paths: some Sequence<String> = [String]()) {
        self.paths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    /// True for a skipped path and anything inside it.
    public func matches(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return paths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
