import AppKit
import IOKit.pwr_mgt
import StewardKit
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/Steward.app/Contents/MacOS/Steward
/// writes <page>-light.png and <page>-dark.png for every sidebar page, and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=scan,review limits the pages (scene names in SnapshotScene). Add "settings" to include Settings.
/// Add APP_ACCENT=<id> to see the pages in another accent.
enum Snapshot {
    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        // Snapshots never run against the real database.
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for scene in SnapshotScene.all where only?.contains(scene.name) ?? true {
                    model.review = nil
                    try? await Task.sleep(for: .seconds(0.3))
                    scene.setup(model)
                    try? await Task.sleep(for: .seconds(scene.sheet ? 1.2 : 0.8))
                    let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                    capture(to: "\(dir)/\(scene.name)-\(mode).png", window: scene.sheet ? main?.attachedSheet : nil)
                }
                model.review = nil
            }
            if only == nil || only?.contains("settings") == true {
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(0.8))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                }
            }
            print("SNAPSHOT done \(dir)")
            // An open sheet refuses terminate, and the run would wait forever.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (for example, your terminal).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars and glass blank.
    private static func capture(to path: String, window: NSWindow? = nil) {
        // Another app can hide this one while snapshots run (computer use hides
        // apps it does not control). Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        // Active, like a window someone is using: real accent colors and focus rings.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}

/// One snapshot page: a sidebar page in one state, or a sheet.
struct SnapshotScene {
    let name: String
    var sheet = false
    let setup: (AppModel) -> Void

    static var all: [SnapshotScene] {
        var scenes: [SnapshotScene] = [
            SnapshotScene(name: "access") { m in
                m.sidebar = .scan; m.hasFullDiskAccess = false; m.accessSkipped = false; m.phase = .idle
            },
            SnapshotScene(name: "scan") { m in
                m.sidebar = .scan; m.hasFullDiskAccess = true; m.phase = .idle
            },
            SnapshotScene(name: "scan-running") { m in
                m.sidebar = .scan; m.hasFullDiskAccess = true
                m.phase = .running(current: .xcodeBuild, count: 412, bytes: 3_200_000_000)
            },
            SnapshotScene(name: "scan-results") { m in loadResults(m) },
            SnapshotScene(name: "review", sheet: true) { m in loadResults(m); m.openReview() },
            SnapshotScene(name: "clean-done") { m in
                loadResults(m)
                let moved = m.tickedItems.map { MovedItem(original: $0.url, inTrash: $0.url, size: $0.size) }
                m.lastClean = CleanSummary(source: .smartScan, moved: moved, failed: [
                    FailedItem(url: m.home.appending(path: "Library/Caches/com.google.Chrome/Default"), message: "In use"),
                ])
                m.phase = .done
            },
            SnapshotScene(name: "scan-empty") { m in
                m.sidebar = .scan; m.hasFullDiskAccess = true; m.items = []; m.notScanned = []; m.phase = .results
            },
        ]
        scenes += [
            SnapshotScene(name: "largeFiles") { m in m.largeFiles.loadSample(); m.largeFiles.age = .any; m.sidebar = .largeFiles },
            SnapshotScene(name: "large-files-old") { m in m.largeFiles.loadSample(); m.largeFiles.age = .oneYear; m.sidebar = .largeFiles },
            SnapshotScene(name: "large-files-empty") { m in
                m.largeFiles.loadSample(); m.largeFiles.files = []; m.largeFiles.age = .any; m.sidebar = .largeFiles
            },
        ]
        scenes += [
            SnapshotScene(name: "duplicates-idle") { m in m.duplicates.hasScanned = false; m.duplicates.groups = []; m.sidebar = .duplicates },
            SnapshotScene(name: "duplicates") { m in m.duplicates.loadSample(); m.sidebar = .duplicates },
            SnapshotScene(name: "duplicates-empty") { m in m.duplicates.loadSample(); m.duplicates.groups = []; m.sidebar = .duplicates },
            SnapshotScene(name: "holding") { m in m.holdingModel.loadSample(home: m.home); m.sidebar = .holding },
            SnapshotScene(name: "holding-empty") { m in m.holdingModel.items = []; m.holdingModel.hasLoaded = true; m.sidebar = .holding },
        ]
        scenes += [
            SnapshotScene(name: "diskMap") { m in m.diskMap.loadSample(); m.sidebar = .diskMap },
            SnapshotScene(name: "disk-map-drill") { m in
                m.diskMap.loadSample(); m.diskMap.path = [m.home.appending(path: "Documents").path]; m.sidebar = .diskMap
            },
        ]
        scenes += [
            SnapshotScene(name: "uninstaller") { m in
                m.uninstaller.loadSample(); m.uninstaller.mode = .apps; m.uninstaller.selection = nil; m.sidebar = .uninstaller
            },
            SnapshotScene(name: "uninstaller-detail") { m in m.uninstaller.loadSample(); m.uninstaller.mode = .apps; m.sidebar = .uninstaller },
            SnapshotScene(name: "uninstaller-orphans") { m in m.uninstaller.loadSample(); m.uninstaller.mode = .leftovers; m.sidebar = .uninstaller },
        ]
        scenes.append(SnapshotScene(name: "loginItems") { m in m.loginItems.loadSample(); m.sidebar = .loginItems })
        scenes += [
            SnapshotScene(name: "unusedApps") { m in m.uninstaller.loadSample(); m.sidebar = .unusedApps },
            SnapshotScene(name: "permissions") { m in m.permissions.loadSample(); m.sidebar = .permissions },
            SnapshotScene(name: "permissions-locked") { m in m.permissions.loadSample(); m.permissions.isLocked = true; m.sidebar = .permissions },
            SnapshotScene(name: "updates") { m in m.updates.loadSample(); m.sidebar = .updates },
            SnapshotScene(name: "background") { m in m.background.loadSample(); m.sidebar = .background },
            SnapshotScene(name: "browserData") { m in m.browserData.loadSample(); m.sidebar = .browserData },
            SnapshotScene(name: "recentItems") { m in m.recentItems.loadSample(); m.sidebar = .recentItems },
            SnapshotScene(name: "status") { m in
                m.status.loadSample(); m.uninstaller.loadSample(); m.loginItems.loadSample(); m.browserData.loadSample()
                m.items = SeedData.scanItems(home: m.home); m.scannedAt = Date.now.addingTimeInterval(-7_200)
                m.sidebar = .overview
            },
            SnapshotScene(name: "battery") { m in m.status.loadSample(); m.sidebar = .battery },
            SnapshotScene(name: "battery-none") { m in m.status.loadSample(battery: false); m.sidebar = .battery },
        ]
        let custom: Set<SidebarItem> = [.scan, .largeFiles, .duplicates, .holding, .diskMap, .uninstaller, .loginItems, .unusedApps, .permissions,
                                        .updates, .background, .browserData, .recentItems, .overview, .battery]
        for page in SidebarItem.allCases where !custom.contains(page) {
            scenes.append(SnapshotScene(name: page.rawValue) { m in m.sidebar = page })
        }
        return scenes
    }

    private static func loadResults(_ m: AppModel) {
        m.sidebar = .scan
        m.hasFullDiskAccess = false
        m.accessSkipped = true
        m.items = SeedData.scanItems(home: m.home)
        m.ticked = Set(m.items.filter(\.category.isRecommended).map(\.id))
        m.notScanned = [m.home.appending(path: "Library/Caches/com.apple.Safari")]
        m.phase = .results
        m.scannedAt = Date.now.addingTimeInterval(-7_200)
    }
}
