import AppKit
import Foundation
import SwiftData
import StewardKit

// MARK: - Stored data

/// One Move to Trash run, shown in History.
@Model
final class CleanRecord {
    var date: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \CleanEntry.record)
    var entries: [CleanEntry] = []
    var uuid: UUID = UUID()

    init(date: Date = .now) { self.date = date }

    var bytes: Int64 { entries.reduce(0) { $0 + $1.size } }
}

/// One item a clean moved to the Trash.
@Model
final class CleanEntry {
    var originalPath: String = ""
    var trashPath: String = ""
    var size: Int64 = 0
    var categoryTitle: String = ""
    var record: CleanRecord?

    init(originalPath: String, trashPath: String, size: Int64, categoryTitle: String) {
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.size = size
        self.categoryTitle = categoryTitle
    }

    var isStillInTrash: Bool { FileManager.default.fileExists(atPath: trashPath) }
}

/// A path Steward never chooses (Skipped Items).
@Model
final class SkipRule {
    var path: String = ""
    var addedAt: Date = Date.now

    init(path: String) { self.path = path }
}

// MARK: - Modules and pages

/// One group of tools in the suite, shown as a sidebar section. Add a module
/// by adding a case here and its pages to SidebarItem.
enum Module: String, CaseIterable, Identifiable {
    case status, storage, apps, startup, privacy

    var id: String { rawValue }
    /// The short name in the module bar.
    var shortTitle: String {
        switch self {
        case .status: "Status"
        case .storage: "Storage"
        case .apps: "Apps"
        case .startup: "Startup"
        case .privacy: "Privacy"
        }
    }
    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .storage: "internaldrive"
        case .apps: "square.grid.2x2"
        case .startup: "power"
        case .privacy: "hand.raised"
        }
    }
    /// ⌘1 to ⌘5.
    var shortcut: Character { Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)) }
    var title: String {
        switch self {
        case .storage: "Storage"
        case .apps: "Apps"
        case .startup: "Startup & Background"
        case .privacy: "Privacy"
        case .status: "System Status"
        }
    }
    var pages: [SidebarItem] { SidebarItem.allCases.filter { $0.module == self } }
}

/// The sidebar pages. Snapshot mode walks through every case.
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, battery
    case scan, largeFiles, duplicates, diskMap, holding
    case uninstaller, unusedApps, permissions, updates
    case loginItems, background
    case browserData, recentItems
    case history

    var id: String { rawValue }

    /// nil for pages shared by every module (History).
    var module: Module? {
        switch self {
        case .scan, .largeFiles, .duplicates, .diskMap, .holding: .storage
        case .uninstaller, .unusedApps, .permissions, .updates: .apps
        case .loginItems, .background: .startup
        case .browserData, .recentItems: .privacy
        case .overview, .battery: .status
        case .history: nil
        }
    }

    var title: String {
        switch self {
        case .scan: "Smart Scan"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .diskMap: "Disk Map"
        case .holding: "Trash & Holding"
        case .uninstaller: "Uninstaller"
        case .unusedApps: "Unused Apps"
        case .permissions: "Permissions"
        case .updates: "Updates"
        case .loginItems: "Login Items"
        case .background: "Background Activity"
        case .browserData: "Browser Data"
        case .recentItems: "Recent Items"
        case .overview: "Overview"
        case .battery: "Battery"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .scan: "sparkle.magnifyingglass"
        case .largeFiles: "doc.badge.clock"
        case .duplicates: "doc.on.doc"
        case .diskMap: "square.grid.3x3.square"
        case .holding: "trash"
        case .uninstaller: "app.badge.checkmark"
        case .unusedApps: "moon.zzz"
        case .permissions: "hand.raised"
        case .updates: "arrow.down.app"
        case .loginItems: "power"
        case .background: "waveform.path.ecg"
        case .browserData: "safari"
        case .recentItems: "clock"
        case .overview: "gauge.with.dots.needle.67percent"
        case .battery: "battery.75percent"
        case .history: "clock.arrow.circlepath"
        }
    }


}

enum Count {
    /// "1 item", "12 items"; `capitalized` gives "1 Item", "12 Items" for titles.
    static func items(_ n: Int, capitalized: Bool = false) -> String {
        let word = n == 1 ? "item" : "items"
        return "\(n) \(capitalized ? word.capitalized : word)"
    }
}

enum Bytes {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum SystemSettings {
    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
