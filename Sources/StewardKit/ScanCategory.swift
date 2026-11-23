import Foundation

/// A group of Smart Scan results of one kind. Every location is inside the
/// home folder: Steward works at user level only.
public enum ScanCategory: String, CaseIterable, Sendable, Codable {
    case appCaches, logs, unfinishedDownloads
    case xcodeBuild, simulatorCaches, deviceSupport, xcodeArchives
    case packageCaches, projectBuilds

    public var title: String {
        switch self {
        case .appCaches: "App Caches"
        case .logs: "Old Logs"
        case .unfinishedDownloads: "Unfinished Downloads"
        case .xcodeBuild: "Xcode Build Files"
        case .simulatorCaches: "Simulator Caches"
        case .deviceSupport: "Device Support Files"
        case .xcodeArchives: "Xcode Archives"
        case .packageCaches: "Package Manager Caches"
        case .projectBuilds: "Old Project Dependencies"
        }
    }

    /// Why Steward chose these items, in one line.
    public var reason: String {
        switch self {
        case .appCaches: "Apps rebuild these when needed."
        case .logs: "Records apps keep for troubleshooting, untouched for a week or more."
        case .unfinishedDownloads: "Downloads that stopped before they finished."
        case .xcodeBuild: "Xcode rebuilds these the next time you build."
        case .simulatorCaches: "Simulator rebuilds these when it starts."
        case .deviceSupport: "Xcode downloads these again when you connect a device."
        case .xcodeArchives: "Builds you archived. Keep the ones you need to read crash reports."
        case .packageCaches: "Homebrew, npm, CocoaPods, SwiftPM, and others download these again when needed."
        case .projectBuilds: "node_modules, .build, Pods, and target folders in projects untouched for 90 days. A build or install brings them back."
        }
    }

    /// Ticked by default because apps rebuild these on their own.
    public var isRecommended: Bool {
        switch self {
        case .appCaches, .logs, .unfinishedDownloads, .xcodeBuild, .simulatorCaches: true
        case .deviceSupport, .xcodeArchives, .packageCaches, .projectBuilds: false
        }
    }

    /// For developers; the Smart Scan settings group these.
    public var isDeveloper: Bool {
        switch self {
        case .appCaches, .logs, .unfinishedDownloads: false
        default: true
        }
    }

    public var symbol: String {
        switch self {
        case .appCaches: "shippingbox"
        case .logs: "doc.text"
        case .unfinishedDownloads: "arrow.down.circle.dotted"
        case .xcodeBuild: "hammer"
        case .simulatorCaches: "iphone"
        case .deviceSupport: "cable.connector"
        case .xcodeArchives: "archivebox"
        case .packageCaches: "cube.box"
        case .projectBuilds: "folder.badge.gearshape"
        }
    }

    /// Items untouched for fewer days than this are left alone. nil means any age.
    public var minimumAgeDays: Int? {
        switch self {
        case .logs: 7
        case .projectBuilds: 90
        default: nil
        }
    }

    /// Package manager caches that live in ~/Library/Caches. They show under
    /// Package Manager Caches, never App Caches, so nothing is counted twice.
    static let packageCacheNames: Set<String> = [
        "Homebrew", "CocoaPods", "org.swift.swiftpm", "Yarn", "pip", "go-build", "pypoetry", "node-gyp", "ms-playwright",
    ]

    /// Folders, relative to the home folder, whose children are the items.
    /// Project Dependencies searches `projectRoots` instead.
    var folders: [String] {
        switch self {
        case .appCaches: ["Library/Caches"]
        case .logs: ["Library/Logs"]
        case .unfinishedDownloads: ["Downloads"]
        case .xcodeBuild: ["Library/Developer/Xcode/DerivedData"]
        case .simulatorCaches: ["Library/Developer/CoreSimulator/Caches"]
        case .deviceSupport: [
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/tvOS DeviceSupport",
            "Library/Developer/Xcode/visionOS DeviceSupport",
        ]
        case .xcodeArchives: ["Library/Developer/Xcode/Archives"]
        case .packageCaches: Array(Self.packageFolders.keys).sorted()
        case .projectBuilds: []
        }
    }

    /// Package manager folders and the children of each that are caches.
    static let packageFolders: [String: Set<String>] = [
        "Library/Caches": packageCacheNames,
        ".npm": ["_cacache", "_npx", "_logs"],
        ".gradle": ["caches", "wrapper", "daemon"],
        ".cargo/registry": ["cache", "src"],
        ".yarn/berry": ["cache"],
        ".bun/install": ["cache"],
        "Library/pnpm": ["store"],
        ".m2": ["repository"],
    ]

    /// Where Old Project Dependencies looks for projects, relative to the home folder.
    public static let projectRoots = ["Developer", "Projects", "Code", "code", "src", "Sites", "GitHub", "repos", "workspace", "Documents", "Desktop"]

    /// Folders a project rebuilds, and the file next to them that marks the project.
    public static let projectArtifacts: [String: String] = [
        "node_modules": "package.json",
        ".build": "Package.swift",
        "Pods": "Podfile",
        "target": "Cargo.toml",
    ]

    /// Whether a child of `folder` (one of `folders`) belongs to this category.
    func accepts(_ name: String, in folder: String) -> Bool {
        if name.hasPrefix(".") { return false }
        switch self {
        case .unfinishedDownloads:
            let ext = (name as NSString).pathExtension.lowercased()
            return ["crdownload", "download", "part", "partial", "opdownload"].contains(ext)
        case .appCaches:
            // Never offer Steward's own cache, or package caches (they have their own category).
            return !name.hasPrefix("com.peri.steward") && !Self.packageCacheNames.contains(name)
        case .packageCaches:
            return Self.packageFolders[folder]?.contains(name) ?? false
        default:
            return true
        }
    }
}

/// An app that is open right now.
public struct RunningApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum CacheOwner {
    /// The open app a cache folder belongs to: named after its bundle id (or a
    /// helper of it, like com.vendor.app.helper), or after the app itself.
    /// Moving a cache out from under an open app can make it misbehave.
    public static func runningOwner(ofCacheNamed name: String, running: [RunningApp]) -> RunningApp? {
        let lower = name.lowercased()
        return running.first { app in
            let id = app.bundleID.lowercased()
            return lower == id || lower.hasPrefix(id + ".") || lower == app.name.lowercased()
        }
    }
}
