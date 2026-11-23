import Foundation
import StewardKit
import SwiftData

/// Sample data for snapshots: APP_SEED=1 with APP_STORE in /tmp fills an
/// empty store with past cleans and skipped items. Scan results for the
/// snapshot scenes come from `scanItems`. Everything here is something a
/// person can produce in the app: a scan, a clean, Always Skip.
@MainActor
enum SeedData {
    static func insertIfRequested(into model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        let context = model.container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<CleanRecord>())) ?? 0) == 0 else { return }
        let cleans: [(Double, [(String, Int64, ScanCategory)])] = [
            (-3_600 * 2, [
                ("Library/Caches/com.google.Chrome", 1_840_000_000, .appCaches),
                ("Library/Caches/com.spotify.client", 912_000_000, .appCaches),
                ("Library/Logs/DiagnosticReports", 48_000_000, .logs),
            ]),
            (-86_400 * 6, [
                ("Library/Developer/Xcode/DerivedData/Weather-fkzqbvxyrmw", 3_420_000_000, .xcodeBuild),
                ("Downloads/ubuntu-24.04-desktop-arm64.iso.crdownload", 1_210_000_000, .unfinishedDownloads),
            ]),
        ]
        for (offset, entries) in cleans {
            let record = CleanRecord(date: Date.now.addingTimeInterval(offset))
            context.insert(record)
            for (path, size, category) in entries {
                let entry = CleanEntry(
                    originalPath: model.home.appending(path: path).path,
                    trashPath: "/nonexistent/.Trash/\((path as NSString).lastPathComponent)",
                    size: size, categoryTitle: category.title)
                context.insert(entry)
                entry.record = record
            }
        }
        context.insert(SkipRule(path: model.home.appending(path: "Library/Caches/com.apple.Music").path))
        context.insert(SkipRule(path: model.home.appending(path: "Library/Developer/Xcode/DerivedData/Steward-current").path))
        try? context.save()
    }

    /// Realistic Smart Scan results under the given home folder.
    static func scanItems(home: URL) -> [ScanItem] {
        let samples: [(String, Int64, ScanCategory, Double)] = [
            ("Library/Caches/com.google.Chrome", 1_240_000_000, .appCaches, -3_600),
            ("Library/Caches/com.spotify.client", 684_000_000, .appCaches, -7_200),
            ("Library/Caches/com.tinyspeck.slackmacgap", 412_000_000, .appCaches, -86_400),
            ("Library/Caches/org.swift.swiftpm", 238_000_000, .packageCaches, -86_400 * 3),
            ("Library/Caches/com.microsoft.VSCode.ShipIt", 96_000_000, .appCaches, -86_400 * 12),
            ("Library/Caches/Homebrew", 1_061_000_000, .packageCaches, -86_400 * 40),
            (".npm/_cacache", 2_310_000_000, .packageCaches, -86_400 * 6),
            ("Library/Developer/Xcode/Archives/2025-03-14", 920_000_000, .xcodeArchives, -86_400 * 250),
            ("Developer/old-landing-page/node_modules", 612_000_000, .projectBuilds, -86_400 * 180),
            ("Developer/WeatherKitDemo/.build", 1_380_000_000, .projectBuilds, -86_400 * 120),
            ("Library/Logs/DiagnosticReports", 52_000_000, .logs, -86_400 * 2),
            ("Library/Logs/Zoom", 18_400_000, .logs, -86_400 * 20),
            ("Library/Developer/Xcode/DerivedData/Weather-fkzqbvxyrmwq", 2_870_000_000, .xcodeBuild, -86_400 * 9),
            ("Library/Developer/Xcode/DerivedData/Notes-agdhqpzlxbcu", 1_120_000_000, .xcodeBuild, -86_400 * 30),
            ("Library/Developer/CoreSimulator/Caches/dyld", 1_640_000_000, .simulatorCaches, -86_400 * 4),
            ("Library/Developer/Xcode/iOS DeviceSupport/iPhone16,1 18.1 (22B83)", 4_200_000_000, .deviceSupport, -86_400 * 210),
            ("Downloads/ubuntu-24.04-desktop-arm64.iso.crdownload", 1_210_000_000, .unfinishedDownloads, -86_400 * 15),
        ]
        return samples.map { path, size, category, age in
            ScanItem(url: home.appending(path: path), category: category, size: size,
                     lastOpened: Date.now.addingTimeInterval(age))
        }
    }
}
