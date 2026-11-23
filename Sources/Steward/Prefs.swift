import Foundation
import StewardKit

/// Every setting, its key, and its default. Test and snapshot runs use their
/// own store, so they never change the person's real preferences.
enum Prefs {
    static var store: UserDefaults {
        Store.isOverridden ? (UserDefaults(suiteName: "com.peri.steward.tests") ?? .standard) : .standard
    }

    enum Key {
        static let startPage = "general.startPage"
        static let lastPage = "nav.lastPage"
        static let historyDays = "history.keepDays"
        static let menuBar = "status.menuBar"
        static let menuBarShows = "status.menuBarShows"
        static let interval = "status.interval"
        static let lowDiskGB = "status.lowDiskGB"
        static let threshold = "largeFiles.threshold"
        static let largeAge = "largeFiles.age"
        static let diskMapStart = "diskMap.start"
        static let unusedPeriod = "apps.unusedPeriod"
        static let updatesAllowed = "updates.allowed"
        static let tickCache = "privacy.tick.cache"
        static let tickCookies = "privacy.tick.cookies"
        static let tickHistory = "privacy.tick.history"
        static let showApple = "background.showApple"
        static let destination = "clean.destination"
        static let holdingDays = "clean.holdingDays"
        static let duplicateMinSize = "duplicates.minSize"

        static let all = [startPage, lastPage, historyDays, menuBar, menuBarShows, interval, lowDiskGB, threshold, largeAge,
                          diskMapStart, unusedPeriod, updatesAllowed, tickCache, tickCookies, tickHistory, showApple,
                          destination, holdingDays, duplicateMinSize]
    }

    /// "overview" or "last".
    static var startPage: String { store.string(forKey: Key.startPage) ?? "overview" }
    static var lastPage: SidebarItem? { store.string(forKey: Key.lastPage).flatMap(SidebarItem.init(rawValue:)) }
    /// 0 keeps History forever.
    static var historyDays: Int { store.integer(forKey: Key.historyDays) }
    static var menuBar: Bool { store.bool(forKey: Key.menuBar) }
    /// "cpu", "memory", or "both".
    static var menuBarShows: String { store.string(forKey: Key.menuBarShows) ?? "cpu" }
    static var interval: Double { let v = store.double(forKey: Key.interval); return [1, 2, 5].contains(v) ? v : 2 }
    /// 0 is off.
    static var lowDiskGB: Int { store.integer(forKey: Key.lowDiskGB) }
    static var largeAge: FileAge { store.string(forKey: Key.largeAge).flatMap(FileAge.init(rawValue:)) ?? .any }
    /// nil starts the Disk Map at the home folder.
    static var diskMapStart: URL? { store.string(forKey: Key.diskMapStart).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var unusedPeriod: Int { let v = store.integer(forKey: Key.unusedPeriod); return [3, 6, 12].contains(v) ? v : 6 }
    static var updatesAllowed: Bool { store.bool(forKey: Key.updatesAllowed) }
    static func ticksByDefault(_ kind: BrowserDataKind) -> Bool {
        let key = switch kind { case .cache: Key.tickCache; case .cookies: Key.tickCookies; case .history: Key.tickHistory }
        return store.object(forKey: key) as? Bool ?? kind.isRecommended
    }
    static var showApple: Bool { store.bool(forKey: Key.showApple) }
    /// Where cleaned items go. The Trash unless the person chose the holding area.
    static var destination: CleanDestination { store.string(forKey: Key.destination).flatMap(CleanDestination.init(rawValue:)) ?? .trash }
    /// Days items wait in the holding area before Steward deletes them.
    static var holdingDays: Int { let v = store.integer(forKey: Key.holdingDays); return CleanDestination.holdingChoices.contains(v) ? v : 7 }
    /// The smallest file the duplicate finder compares.
    static var duplicateMinSize: Int64 {
        let v = Int64(store.integer(forKey: Key.duplicateMinSize))
        return DuplicateFinder.sizeChoices.contains(v) ? v : DuplicateFinder.sizeChoices[1]
    }

    /// Puts every setting back to its default, including Smart Scan categories and the accent.
    static func resetAll() {
        for key in Key.all { store.removeObject(forKey: key) }
        for category in ScanCategory.allCases { store.removeObject(forKey: ScanSettings.key(category)) }
        if !Store.isOverridden {
            UserDefaults.standard.removeObject(forKey: "appearance.accent")
            ThemeStore.shared.themeID = ThemeStore.defaultID
        }
    }
}
