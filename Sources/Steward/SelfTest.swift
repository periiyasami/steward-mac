import AppKit
import SwiftData
import Foundation
import StewardKit

/// Self-test for agents: runs the app's real functions on a test store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Steward-self.store ~/Applications/Steward.app/Contents/MacOS/Steward --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        guard model.home.path.hasPrefix("/tmp/") || model.home.path.hasPrefix("/private/tmp/"),
              model.fixedTrash is FolderTrash else {
            print("SELFTEST refused: set APP_HOME and APP_TRASH to folders in /tmp")
            finish(code: 1)
            return
        }
        Task {
            Prefs.resetAll()
            // No real app is "open" for the fixture's caches unless a check says so.
            model.runningApps = { [] }
            model.updates.caskrooms = [model.home.appending(path: "Caskroom")]
            try? await Task.sleep(for: .seconds(0.5))
            do { try makeFixture(home: model.home) } catch {
                print("SELFTEST could not build the fixture: \(error)")
                finish(code: 1)
                return
            }
            let fm = FileManager.default
            let context = model.container.mainContext
            func path(_ p: String) -> URL { model.home.appending(path: p) }

            // S-002 Run a Smart Scan, and the window stays responsive.
            model.startScan()
            var slowest: Duration = .zero
            let clock = ContinuousClock()
            while model.isScanning {
                let t = clock.now
                try? await Task.sleep(for: .milliseconds(20))
                slowest = max(slowest, clock.now - t)
            }
            let names = Set(model.items.map(\.name))
            check("Smart Scan finds caches, logs, build files, and unfinished downloads",
                  names.isSuperset(of: ["com.example.app", "Example", "Proj-abc", "movie.mp4.crdownload"]), "\(names)")
            check("Smart Scan leaves documents and finished downloads alone",
                  !names.contains("keep.pdf") && !names.contains("report.pages"))
            check("the main thread stays responsive during a scan", slowest < .milliseconds(250), "\(slowest)")

            // S-003 Results by category, Recommended ticked.
            check("Recommended items are ticked", model.ticked.contains(path("Library/Caches/com.example.app").path))
            check("Device Support Files are not ticked", !model.ticked.contains(path("Library/Developer/Xcode/iOS DeviceSupport/18.0").path))
            let total = model.items(in: .appCaches).reduce(Int64(0)) { $0 + $1.size }
            check("category totals equal the sum of their items", total > 0 && total == model.items.filter { $0.category == .appCaches }.reduce(0) { $0 + $1.size })

            // S-002 Stop keeps results.
            model.startScan()
            model.stopScan()
            check("Stop ends the scan at once", !model.isScanning)
            model.startScan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }

            // S-004 Review, untick one, S-005 Move to Trash.
            let keptURL = path("Library/Logs/Example")
            model.openReview()
            check("Review opens for ticked items", model.review != nil)
            guard let session = model.review else { finish(code: 1); return }
            session.ticked.remove(keptURL.path)
            let chosen = session.tickedRows
            check("unticking in Review leaves the results ticked", model.ticked.contains(keptURL.path))
            model.moveToTrash(session, undoManager: nil)
            while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            let moved = model.lastClean?.moved ?? []
            check("only ticked items move", moved.count == chosen.count && fm.fileExists(atPath: keptURL.path))
            check("moved items are in the Trash", !moved.isEmpty && moved.allSatisfy { fm.fileExists(atPath: $0.inTrash.path) && !fm.fileExists(atPath: $0.original.path) })
            check("the symlink's target is untouched", fm.fileExists(atPath: model.home.deletingLastPathComponent().appending(path: "Steward-self-outside/precious.bin").path))

            // S-006 History.
            let records = (try? context.fetch(FetchDescriptor<CleanRecord>())) ?? []
            check("the clean is saved to History", records.count == 1 && records.first?.entries.count == moved.count)

            // S-005 Undo Move to Trash.
            model.undoLastClean()
            check("Undo puts every item back", moved.allSatisfy { fm.fileExists(atPath: $0.original.path) })
            check("Undo removes the clean from History", ((try? context.fetchCount(FetchDescriptor<CleanRecord>())) ?? -1) == 0)

            // S-007 Always Skip.
            model.startScan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
            if let item = model.items.first(where: { $0.name == "com.example.other" }) {
                model.alwaysSkip(item.url)
                check("Always Skip saves a skipped item", ((try? context.fetchCount(FetchDescriptor<SkipRule>())) ?? 0) == 1)
                model.startScan()
                while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
                check("a skipped item is not found again", !model.items.contains { $0.name == "com.example.other" })
            } else {
                check("Always Skip has an item to skip", false)
            }

            // S-010 to S-014 Large & Old Files.
            let lf = model.largeFiles
            lf.scanMinSize = 25_000
            lf.threshold = 25_000
            lf.scan(skipped: model.skipList())
            while lf.scanning { try? await Task.sleep(for: .milliseconds(20)) }
            check("Large & Old Files finds big files outside ~/Library",
                  lf.visible.contains { $0.name == "report.pages" } && !lf.visible.contains { $0.name == "out.o" })
            lf.ticked = [path("Documents/report.pages").path]
            model.sidebar = .largeFiles
            model.openReviewForCurrentPage()
            check("Review gets exactly the ticked large file", model.review?.rows.map(\.url.lastPathComponent) == ["report.pages"],
                  "rows \(model.review?.rows.map(\.url.path) ?? []), visible \(lf.visible.map(\.url.path)), ticked \(lf.ticked)")
            if let session = model.review {
                model.moveToTrash(session, undoManager: nil)
                while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            check("a moved large file leaves the list", !lf.files.contains { $0.name == "report.pages" })
            model.undoLastClean()
            check("Undo shows the large file again", lf.files.contains { $0.name == "report.pages" })

            // S-015 to S-018 Disk Map.
            let map = model.diskMap
            map.measure(model.home)
            while map.measuring { try? await Task.sleep(for: .milliseconds(20)) }
            let top = map.tree?.children ?? []
            check("Disk Map measures the home folder", (map.tree?.size ?? 0) > 0 && top.contains { $0.name == "Library" })
            check("Disk Map blocks are biggest first", top.map(\.size) == top.map(\.size).sorted(by: >))
            if let docs = top.first(where: { $0.name == "Documents" }) {
                map.open(docs)
                check("clicking a folder goes into it", map.current?.name == "Documents")
                map.up()
                check("Enclosing Folder goes back up", map.path.isEmpty)
            }
            let outside = DiskNode(url: URL(fileURLWithPath: "/System/Library"), size: 1, isDirectory: true)
            map.toggleCollected(outside)
            check("items outside the home folder cannot be added", map.collected.isEmpty)
            if let downloads = top.first(where: { $0.name == "Downloads" }),
               let pdf = downloads.children.first(where: { $0.name == "keep.pdf" }) {
                map.toggleCollected(pdf)
                model.sidebar = .diskMap
                model.openReviewForCurrentPage()
                check("Disk Map items go to Review", model.review?.rows.map(\.url.lastPathComponent) == ["keep.pdf"])
                model.review = nil
            }

            // S-030 to S-033 Uninstaller.
            let un = model.uninstaller
            un.load()
            while un.loading || un.rows.contains(where: { $0.bundleSize == nil }) { try? await Task.sleep(for: .milliseconds(20)) }
            check("the Uninstaller lists the fixture app with its size", un.rows.first?.app.name == "FakeApp" && (un.rows.first?.total ?? 0) > 0)
            un.selection = un.rows.first?.id
            while un.loadingLeftovers { try? await Task.sleep(for: .milliseconds(20)) }
            check("leftovers are found by bundle id", un.leftovers.contains { $0.url.lastPathComponent == "com.example.fake" && $0.isCertain })
            check("a name-only match is left unticked", un.leftovers.contains { $0.url.lastPathComponent == "FakeApp" && !un.leftoverTicks.contains($0.id) })
            model.sidebar = .uninstaller
            un.mode = .apps
            let uninstall = await un.uninstallSession()
            check("Uninstall opens Review with the app and its ticked leftovers",
                  uninstall?.rows.first?.isAppBundle == true && (uninstall?.tickedRows.count ?? 0) >= 3)
            if let uninstall {
                model.moveToTrash(uninstall, undoManager: nil)
                while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            let appPath = path("Applications/FakeApp.app").path
            check("the app moves to the Trash with its leftovers",
                  !fm.fileExists(atPath: appPath) && !fm.fileExists(atPath: path("Library/Containers/com.example.fake").path))
            check("a possible match stays where it was", fm.fileExists(atPath: path("Library/Application Support/FakeApp").path))
            un.loadOrphans()
            while un.loadingOrphans { try? await Task.sleep(for: .milliseconds(20)) }
            check("leftovers of removed apps are found, Apple's never", un.orphans.contains { $0.owner == "com.gone.app" }
                  && !un.orphans.contains { ($0.owner ?? "").hasPrefix("com.apple.") })
            model.undoLastClean()
            check("Undo puts the app back", fm.fileExists(atPath: appPath))

            // S-040 to S-042 Login Items (fake launchd).
            let li = model.loginItems
            li.load()
            while li.loading { try? await Task.sleep(for: .milliseconds(20)) }
            let agent = li.userRows.first { $0.item.label == "com.example.fake.helper" }
            check("Login Items lists user agents with their app", agent?.owner?.name == "FakeApp" && agent?.isOn == true)
            if let agent {
                li.setOn(agent, false)
                check("turning an agent off marks it off", li.userRows.first { $0.id == agent.id }?.isOn == false
                      && li.control.disabledLabels().contains(agent.item.label))
                li.setOn(agent, true)
                check("turning it on again works", li.userRows.first { $0.id == agent.id }?.isOn == true)
            }

            // S-050 to S-052 Speed.
            model.sidebar = .scan
            model.startScan()
            check("Stop is available while a scan runs", model.canStop)
            model.stopCurrent()
            check("Stop from the menu ends the scan", !model.isScanning)
            model.startScan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
            let logs = path("Library/Logs/Example").path
            model.ticked.remove(logs)
            model.scanSelection = [logs]
            model.toggleScanSelection()
            check("Return ticks the selected row", model.ticked.contains(logs))
            model.toggleScanSelection()
            check("Return again unticks it", !model.ticked.contains(logs))
            model.setTicked(.appCaches, false)
            model.scanSelection = ["cat:appCaches"]
            model.toggleScanSelection()
            check("a selected category ticks all its items", model.items(in: .appCaches).allSatisfy { model.ticked.contains($0.id) })
            let savedCount = model.items.count
            try? fm.removeItem(at: path("Downloads/movie.mp4.crdownload"))
            model.phase = .idle
            model.items = []
            model.restoreLastScan()
            check("the last scan is shown again after reopening", model.phase == .results && model.scannedAt != nil && !model.items.isEmpty)
            check("items that no longer exist are dropped", model.items.count == savedCount - 1
                  && !model.items.contains { $0.name == "movie.mp4.crdownload" })

            // S-061 Settings: a category that is off is not scanned.
            ScanSettings.store.set(false, forKey: ScanSettings.key(.logs))
            model.startScan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
            check("a category turned off in Settings is not scanned", !model.items.contains { $0.category == .logs })
            ScanSettings.store.removeObject(forKey: ScanSettings.key(.logs))

            // S-070 to S-073 System Status (live Mac, read-only).
            let st = model.status
            st.wantsTopApps = true
            await st.sample()
            try? await Task.sleep(for: .milliseconds(300))
            await st.sample()
            check("CPU reads 0 to 100", (0...100).contains(st.cpu))
            check("memory used is above zero and under installed memory", (st.memory?.used ?? 0) > 0 && (st.memory?.used ?? .max) <= (st.memory?.total ?? 0))
            check("disk and uptime read", (st.disk?.total ?? 0) > 0 && st.uptime > 0)
            check("top apps are listed biggest first", !st.topApps.isEmpty && st.topApps.map(\.memory) == st.topApps.map(\.memory).sorted(by: >))
            check("app memory includes Steward itself", StatusModel.topApps(from: ProcessSample.all(), limit: 500).contains { $0.name == "Steward" })
            if let b = st.battery {
                check("battery health is a sensible percent", (1...150).contains(b.healthPercent ?? 100))
            } else {
                check("a Mac without a battery reports none", !st.hasBattery)
            }

            // S-081 Unused Apps. Reload the list: test runs don't reload after Undo.
            un.load()
            while un.loading || un.rows.contains(where: { $0.bundleSize == nil }) { try? await Task.sleep(for: .milliseconds(20)) }
            check("Unused Apps sees the fixture app", un.rows.contains { $0.app.name == "FakeApp" })
            if let i = un.rows.firstIndex(where: { $0.app.name == "FakeApp" }) {
                un.rows[i].lastUsed = nil
                un.rows[i].added = .now
                check("a new app with no last-used date is not unused", un.unused(.six).isEmpty)
                un.rows[i].lastUsed = Calendar.current.date(byAdding: .month, value: -8, to: .now)
                check("an app last opened 8 months ago is unused at 6 months", un.unused(.six).map(\.app.name) == ["FakeApp"])
                check("but not at 12 months", un.unused(.twelve).isEmpty)
            }

            // S-082 Permissions.
            let perms = model.permissions
            perms.load()
            while perms.loading { try? await Task.sleep(for: .milliseconds(20)) }
            check("Permissions reads the TCC database", !perms.isLocked && perms.rows(for: .camera).contains { $0.grant.client == "com.example.fake" && $0.grant.allowed })
            check("denied permissions are told apart", perms.rows(for: .microphone).contains { !$0.grant.allowed })
            let locked = PermissionsModel(databases: [URL(fileURLWithPath: "/nonexistent/TCC.db")])
            locked.load()
            while locked.loading { try? await Task.sleep(for: .milliseconds(20)) }
            check("an unreadable database shows the locked state", locked.isLocked)

            // S-083 Updates (a local feed).
            let upd = model.updates
            upd.load(apps: un.rows.map(\.app))
            check("apps with a Sparkle feed are found", upd.checkable.map(\.name) == ["FakeApp"] && upd.checkable.first?.kind.via == "Sparkle")
            await upd.checkAll(allowed: false)
            check("nothing is checked until allowed", upd.checkable.first?.state == .notChecked)
            await upd.checkAll(allowed: true)
            check("a newer version in the feed shows as available", upd.checkable.first?.state == .available("1.1"), "\(String(describing: upd.checkable.first?.state))")

            // S-091 Background Activity (injected jobs, real process info).
            let bg = model.background
            let me = getpid()
            bg.load(loginItems: li.rows) {
                [LaunchJob(label: "com.example.fake.helper", pid: me, lastExitStatus: 0),
                 LaunchJob(label: "com.apple.Finder", pid: 1, lastExitStatus: 0),
                 LaunchJob(label: "com.example.idle", pid: nil, lastExitStatus: 0)]
            }
            while bg.loading { try? await Task.sleep(for: .milliseconds(20)) }
            check("running jobs show with their app and memory", bg.visible.first?.appName == "FakeApp" && (bg.visible.first?.process?.memory ?? 0) > 0)
            check("Apple's jobs are hidden until shown", !bg.visible.contains { $0.job.isApple })
            check("a job from Login Items links to it", bg.visible.first?.loginItemID != nil)
            check("loaded jobs that are not running are counted", bg.stoppedCount == 1)

            // S-100 Browser Data.
            let br = model.browserData
            br.load()
            while br.loading { try? await Task.sleep(for: .milliseconds(20)) }
            check("Chrome's cache, cookies, and history are found", Set(br.items.map(\.kind)) == [.cache, .cookies, .history])
            check("only caches are ticked", br.tickedItems.allSatisfy { $0.kind == .cache } && !br.tickedItems.isEmpty)
            br.runningBundleIDs = { ["com.google.Chrome"] }
            check("a running browser must quit first", br.reviewSession() == nil && br.message != nil)
            br.runningBundleIDs = { [] }
            if let session = br.reviewSession() {
                model.moveToTrash(session, undoManager: nil)
                while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            let chrome = "Library/Application Support/Google/Chrome/Default"
            check("the cache moves to the Trash and history stays", !fm.fileExists(atPath: path("Library/Caches/Google/Chrome/Default").path)
                  && fm.fileExists(atPath: path("\(chrome)/History").path))

            // S-101 Recent Items.
            let rec = model.recentItems
            rec.load()
            check("recent-items lists are found", rec.lists.count == 2)
            if let session = rec.reviewSession() {
                model.moveToTrash(session, undoManager: nil)
                while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            check("recent-items lists move to the Trash", rec.lists.isEmpty)
            await rec.runQuickLookReset()
            check("Reset Thumbnails reports what happened", rec.message?.contains("reset") == true)

            // S-110 Top module bar and page tabs.
            model.show(.status)
            check("Status opens on Overview", model.sidebar == .overview)
            model.show(.storage)
            check("Storage opens on its first page", model.sidebar == .scan)
            model.movePage(by: 1)
            check("Next Page moves to the next tab", model.sidebar == .largeFiles)
            model.movePage(by: -2)
            check("Previous Page wraps around", model.sidebar == .holding)
            model.show(.status)
            model.show(.storage)
            check("a module remembers its last page", model.sidebar == .holding)
            check("modules run Status, Storage, Apps, Startup, Privacy", Module.allCases == [.status, .storage, .apps, .startup, .privacy])

            // S-111 Every setting works (test preferences, never the real ones).
            let prefs = Prefs.store
            check("test runs use their own preferences", prefs !== UserDefaults.standard)
            prefs.set("last", forKey: Prefs.Key.startPage)
            prefs.set(SidebarItem.browserData.rawValue, forKey: Prefs.Key.lastPage)
            check("Open on Last Page Used reopens that page", AppModel(container: model.container).sidebar == .browserData)
            prefs.set("overview", forKey: Prefs.Key.startPage)
            check("Open on Overview starts there", AppModel(container: model.container).sidebar == .overview)
            prefs.set(5.0, forKey: Prefs.Key.interval)
            check("the refresh interval is read", Prefs.interval == 5)
            prefs.set(1_000_000, forKey: Prefs.Key.lowDiskGB)
            model.lastLowSpaceAlert = nil
            st.checkLowSpace(available: st.disk?.available ?? 1)
            check("a low disk space alert fires under the limit", model.lastLowSpaceAlert != nil)
            model.lastLowSpaceAlert = nil
            st.checkLowSpace(available: st.disk?.available ?? 1)
            check("and only once", model.lastLowSpaceAlert == nil)
            prefs.set(0, forKey: Prefs.Key.lowDiskGB)
            prefs.set("both", forKey: Prefs.Key.menuBarShows)
            check("menu bar contents are read", Prefs.menuBarShows == "both")
            prefs.set(FileAge.oneYear.rawValue, forKey: Prefs.Key.largeAge)
            check("Large & Old Files opens with the chosen age", LargeFilesModel(home: model.home).age == .oneYear)
            prefs.set(path("Documents").path, forKey: Prefs.Key.diskMapStart)
            check("Disk Map starts in the chosen folder", DiskMapModel(home: model.home).root.path == path("Documents").path)
            prefs.set(12, forKey: Prefs.Key.unusedPeriod)
            check("the Unused Apps period is read", Prefs.unusedPeriod == 12)
            prefs.set(true, forKey: Prefs.Key.showApple)
            check("Apple's background jobs show when chosen", BackgroundModel(home: model.home, appFolders: []).showsApple)
            try? fm.createDirectory(at: path("Library/Caches/Google/Chrome/Default/Cache"), withIntermediateDirectories: true)
            try? Data(count: 4_000).write(to: path("Library/Caches/Google/Chrome/Default/Cache/data_1"))
            prefs.set(true, forKey: Prefs.Key.tickHistory)
            br.load()
            while br.loading { try? await Task.sleep(for: .milliseconds(20)) }
            check("browser history is ticked when chosen", br.tickedItems.contains { $0.kind == .history })
            _ = context
            context.insert(CleanRecord(date: Date.now.addingTimeInterval(-86_400 * 400)))
            context.insert(CleanRecord(date: .now))
            try? context.save()
            prefs.set(365, forKey: Prefs.Key.historyDays)
            model.pruneHistory()
            let kept = (try? context.fetch(FetchDescriptor<CleanRecord>())) ?? []
            check("History older than the retention is removed, recent stays",
                  !kept.isEmpty && kept.allSatisfy { $0.date > Date.now.addingTimeInterval(-86_400 * 365) })
            model.clearHistory()
            check("Clear History empties it", ((try? context.fetchCount(FetchDescriptor<CleanRecord>())) ?? -1) == 0)
            prefs.set(false, forKey: ScanSettings.key(.appCaches))
            Prefs.resetAll()
            check("Reset All Settings restores every default", Prefs.Key.all.allSatisfy { prefs.object(forKey: $0) == nil }
                  && ScanSettings.isEnabled(.appCaches) && Prefs.startPage == "overview")

            // S-120 A cache whose app is open is found but left unticked.
            model.runningApps = { [RunningApp(bundleID: "com.example.app", name: "Example")] }
            model.sidebar = .scan
            model.startScan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
            let openCache = path("Library/Caches/com.example.app").path
            check("a cache of an open app is found but not ticked", model.items.contains { $0.id == openCache }
                  && !model.ticked.contains(openCache) && model.openOwners[openCache] == "Example")
            model.runningApps = { [] }

            // S-121 Old Logs leave fresh logs alone. S-122 Developer cleanup.
            try? fm.createDirectory(at: path("Library/Logs/Fresh"), withIntermediateDirectories: true)
            try? Data(count: 3_000).write(to: path("Library/Logs/Fresh/today.log"))
            model.startScan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
            check("a log written today is not offered", !model.items.contains { $0.name == "Fresh" } && model.items.contains { $0.name == "Example" })
            let npm = model.items.first { $0.category == .packageCaches && $0.name == "_cacache" }
            let modules = model.items.first { $0.category == .projectBuilds }
            check("package caches and old project dependencies are found", npm != nil
                  && modules?.url.path == path("Developer/old-site/node_modules").path, "\(model.items.filter(\.category.isDeveloper).map(\.url.path))")
            check("developer extras are not ticked for you", [npm?.id, modules?.id].compactMap { $0 }.allSatisfy { !model.ticked.contains($0) })

            // S-130 to S-132 The holding area.
            Prefs.store.set(CleanDestination.holding.rawValue, forKey: Prefs.Key.destination)
            check("choosing the holding area sends cleans there", model.trash is HoldingArea)
            model.openReview()
            if let session = model.review {
                model.moveToTrash(session, undoManager: nil)
                while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            let held = model.lastClean?.moved ?? []
            check("cleaned items wait in the holding area", !held.isEmpty
                  && held.allSatisfy { model.holding.contains($0.inTrash) && fm.fileExists(atPath: $0.inTrash.path) && !fm.fileExists(atPath: $0.original.path) })
            let hm = model.holdingModel
            hm.load()
            while hm.loading { try? await Task.sleep(for: .milliseconds(20)) }
            check("Trash & Holding lists what is held", hm.items.count == held.count, "\(hm.items.count) of \(held.count)")
            if let first = hm.items.first {
                hm.selection = [first.id]
                model.putBackSelection()
                check("Put Back returns an item to where it was", first.original.map { fm.fileExists(atPath: $0.path) } ?? false)
                while hm.loading { try? await Task.sleep(for: .milliseconds(20)) }
            }
            model.purgeHolding(now: Date.now.addingTimeInterval(8 * 86_400))
            for _ in 0..<200 where !(hm.items.isEmpty && !hm.loading) { try? await Task.sleep(for: .milliseconds(20)) }
            check("held items are deleted for good after 7 days", hm.items.isEmpty && held.allSatisfy { !fm.fileExists(atPath: $0.inTrash.path) })
            check("deleting a held symlink leaves its target alone",
                  fm.fileExists(atPath: model.home.deletingLastPathComponent().appending(path: "Steward-self-outside/precious.bin").path))
            Prefs.store.removeObject(forKey: Prefs.Key.destination)
            check("the Trash is the default", model.trash is FolderTrash)

            // S-140 to S-142 Duplicates.
            let dm = model.duplicates
            dm.minSize = 100_000
            dm.scan(skipped: model.skipList())
            while dm.scanning { try? await Task.sleep(for: .milliseconds(20)) }
            check("Duplicates finds files with the same contents", dm.groups.count == 1 && dm.groups.first?.files.count == 2,
                  "\(dm.groups.map { $0.files.map(\.url.path) })")
            check("the copy outside Downloads is suggested to keep", dm.groups.first?.keep.url.path == path("Documents/Dup/movie.bin").path)
            dm.ticked = Set(dm.allFiles.map(\.id))
            model.sidebar = .duplicates
            model.openReviewForCurrentPage()
            check("Review never takes every copy", model.review?.rows.map(\.url.path) == [path("Downloads/movie copy.bin").path])
            if let session = model.review {
                model.moveToTrash(session, undoManager: nil)
                while model.cleaning || model.review != nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            check("the extra copy moves and the group leaves the list", dm.groups.isEmpty && fm.fileExists(atPath: path("Documents/Dup/movie.bin").path))
            model.undoLastClean()
            check("Undo shows the group again", dm.groups.count == 1)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// A fixture home folder with junk, keepers, and a symlink pointing out.
    private static func makeFixture(home: URL) throws {
        let fm = FileManager.default
        let outside = home.deletingLastPathComponent().appending(path: "Steward-self-outside")
        try? fm.removeItem(at: home)
        try? fm.removeItem(at: outside)
        func write(_ p: String, _ bytes: Int) throws {
            let url = home.appending(path: p)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        try write("Library/Caches/com.example.app/cache.db", 40_000)
        try write("Library/Caches/com.example.other/b.bin", 10_000)
        try write("Library/Logs/Example/x.log", 5_000)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86_400)],
                             ofItemAtPath: home.appending(path: "Library/Logs/Example/x.log").path)
        try write("Library/Developer/Xcode/DerivedData/Proj-abc/out.o", 80_000)
        try write("Library/Developer/Xcode/iOS DeviceSupport/18.0/sym.bin", 20_000)
        try write("Downloads/movie.mp4.crdownload", 30_000)
        try write("Downloads/keep.pdf", 30_000)
        try write("Documents/report.pages", 30_000)
        // Developer cleanup: a package cache and an old project.
        try write(".npm/_cacache/content/a", 6_000)
        try write("Developer/old-site/package.json", 200)
        try write("Developer/old-site/node_modules/left-pad/index.js", 9_000)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-200 * 86_400)],
                             ofItemAtPath: home.appending(path: "Developer/old-site/package.json").path)
        // Duplicates: the same contents in two places.
        try write("Documents/Dup/movie.bin", 150_000)
        try write("Downloads/movie copy.bin", 150_000)
        // An app with leftovers, for the Uninstaller.
        let contents = home.appending(path: "Applications/FakeApp.app/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let feed = home.appending(path: "appcast.xml")
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.fake", "CFBundleShortVersionString": "1.0",
                                    "SUFeedURL": feed.absoluteString]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        try write("Applications/FakeApp.app/Contents/MacOS/FakeApp", 20_000)
        try Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>1.1</title><enclosure url="x" sparkle:shortVersionString="1.1" sparkle:version="11"/></item>
        </channel></rss>
        """.utf8).write(to: feed)
        // Privacy: a TCC database, a Chrome profile, and recent-items lists.
        let tcc = home.appending(path: "Library/Application Support/com.apple.TCC")
        try fm.createDirectory(at: tcc, withIntermediateDirectories: true)
        let sql = Process()
        sql.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sql.arguments = [tcc.appending(path: "TCC.db").path, """
        CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, last_modified INTEGER);
        INSERT INTO access VALUES ('kTCCServiceCamera','com.example.fake',0,2,1700000000);
        INSERT INTO access VALUES ('kTCCServiceMicrophone','com.example.fake',0,0,1700000000);
        """]
        try sql.run()
        sql.waitUntilExit()
        try write("Library/Application Support/Google/Chrome/Default/History", 6_000)
        try write("Library/Application Support/Google/Chrome/Default/Cookies", 2_000)
        try write("Library/Caches/Google/Chrome/Default/Cache/data_0", 9_000)
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3", 300)
        try write("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentApplications.sfl3", 300)
        try write("Library/Containers/com.example.fake/Data/x", 2_000)
        try write("Library/Preferences/com.example.fake.plist", 100)
        try write("Library/Saved Application State/com.example.fake.savedState/w", 100)
        try write("Library/Application Support/FakeApp/cache", 1_000)
        try write("Library/Containers/com.gone.app/Data/x", 3_000)
        let agents = home.appending(path: "Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let agent: [String: Any] = ["Label": "com.example.fake.helper", "ProgramArguments": ["/usr/local/bin/fakehelper"], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: agents.appending(path: "com.example.fake.helper.plist"))
        try write("Library/Containers/com.apple.Notes/Data/x", 3_000)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: outside.appending(path: "precious.bin"))
        try fm.createSymbolicLink(at: home.appending(path: "Library/Caches/link-out"), withDestinationURL: outside)
    }

    /// Read-only run against the real Mac: lists what each module finds and quits.
    /// Nothing moves and nothing is fetched. `Steward --probe` with APP_STORE in /tmp.
    static func probeIfRequested(model: AppModel) {
        guard CommandLine.arguments.contains("--probe"), Store.isOverridden else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            let st = model.status
            st.wantsTopApps = true
            await st.sample(); try? await Task.sleep(for: .seconds(1)); await st.sample()
            print("PROBE status cpu=\(Int(st.cpu))% mem=\(Bytes.text(Int64(st.memory?.used ?? 0)))/\(Bytes.text(Int64(st.memory?.total ?? 0))) disk-free=\(Bytes.text(st.disk?.available ?? 0)) uptime=\(Int(st.uptime / 3600))h top=\(st.topApps.map(\.name))")
            if let b = st.battery { print("PROBE battery health=\(b.healthPercent ?? -1)% cycles=\(b.cycleCount ?? -1) charge=\(b.chargePercent ?? -1)%") } else { print("PROBE battery none") }
            let un = model.uninstaller
            un.load()
            while un.loading || un.rows.contains(where: { $0.bundleSize == nil }) { try? await Task.sleep(for: .milliseconds(50)) }
            print("PROBE apps \(un.rows.count) installed, unused 6 months: \(un.unused(.six).map(\.app.name))")
            let perms = model.permissions
            perms.load()
            while perms.loading { try? await Task.sleep(for: .milliseconds(50)) }
            print("PROBE permissions locked=\(perms.isLocked) grants=\(perms.rows.count) services=\(perms.services.map(\.title))")
            model.updates.load(apps: un.rows.map(\.app))
            print("PROBE updates sparkle=\(model.updates.checkable.map(\.name)) appStore=\(model.updates.others.filter { $0.state == .appStore }.count) (not fetched)")
            let li = model.loginItems
            li.load()
            while li.loading { try? await Task.sleep(for: .milliseconds(50)) }
            print("PROBE login items user=\(li.userRows.count) system=\(li.systemRows.count)")
            let bg = model.background
            bg.load(loginItems: li.rows)
            while bg.loading { try? await Task.sleep(for: .milliseconds(50)) }
            print("PROBE background running=\(bg.visible.count) stopped=\(bg.stoppedCount) top=\(bg.visible.prefix(5).map(\.name))")
            let br = model.browserData
            br.load()
            while br.loading { try? await Task.sleep(for: .milliseconds(50)) }
            print("PROBE browsers \(br.browsers) items=\(br.items.count) cache=\(Bytes.text(br.items.filter { $0.kind == .cache }.reduce(0) { $0 + $1.size }))")
            model.recentItems.load()
            print("PROBE recent lists=\(model.recentItems.lists.map(\.title))")
            print("PROBE done")
            NSApp.terminate(nil)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
