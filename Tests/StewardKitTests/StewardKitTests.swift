import Foundation
import Testing
import UniformTypeIdentifiers
@testable import StewardKit

/// A throwaway home folder with junk, keepers, and traps.
struct Fixture {
    let root: URL
    let home: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "steward-test-\(UUID().uuidString)")
        home = root.appending(path: "home")
        outside = root.appending(path: "outside")
        try write("Library/Caches/com.example.app/cache.db", bytes: 40_000)
        try write("Library/Caches/com.example.other/a/b.bin", bytes: 10_000)
        try write("Library/Caches/com.peri.steward/own.bin", bytes: 10_000)
        try write("Library/Logs/Example/x.log", bytes: 5_000)
        // Old enough for Old Logs (a week).
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86_400)],
                                              ofItemAtPath: home.appending(path: "Library/Logs/Example/x.log").path)
        try write("Library/Developer/Xcode/DerivedData/Proj-abc/Build/out.o", bytes: 80_000)
        try write("Library/Developer/Xcode/iOS DeviceSupport/18.0/sym.bin", bytes: 20_000)
        try write("Downloads/movie.mp4.crdownload", bytes: 30_000)
        try write("Downloads/keep.pdf", bytes: 30_000)
        try write("Documents/report.pages", bytes: 30_000)
        // A symlink in Caches pointing outside the home folder.
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: outside.appending(path: "precious.bin"))
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: "Library/Caches/link-out"), withDestinationURL: outside)
    }

    func write(_ path: String, bytes: Int) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ScannerTests {
    @Test func findsJunkAndLeavesKeepers() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (items, _) = await Scanner(home: f.home).run()
        let names = Set(items.map(\.name))
        #expect(names.isSuperset(of: ["com.example.app", "com.example.other", "Example", "Proj-abc", "18.0", "movie.mp4.crdownload"]))
        #expect(!names.contains("keep.pdf"))
        #expect(!names.contains("report.pages"))
        #expect(!names.contains("com.peri.steward"))
    }

    @Test func symlinksCountAsThemselvesNeverTheirTarget() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (items, _) = await Scanner(home: f.home).run()
        let link = items.first { $0.name == "link-out" }
        #expect((link?.size ?? 0) < 100_000)
    }

    @Test func recommendedFollowsCategory() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (items, _) = await Scanner(home: f.home).run()
        #expect(items.first { $0.name == "18.0" }?.category.isRecommended == false)
        #expect(items.first { $0.name == "Proj-abc" }?.category.isRecommended == true)
    }

    @Test func skippedItemsAreNeverReturned() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let skip = SkipList([f.home.appending(path: "Library/Caches/com.example.app").path])
        let (items, _) = await Scanner(home: f.home, skipped: skip).run()
        #expect(!items.contains { $0.name == "com.example.app" })
        #expect(items.contains { $0.name == "com.example.other" })
    }

    @Test func folderSizeSumsTheTree() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let size = Sizer.allocatedSize(of: f.home.appending(path: "Library/Caches/com.example.other"))
        #expect(size >= 10_000)
    }
}

@Suite struct SafetyTests {
    let home = URL(fileURLWithPath: "/Users/someone")

    @Test func insideHomeIsAllowed() {
        #expect(PathGuard.isAllowed(home.appending(path: "Library/Caches/com.x"), home: home))
    }

    @Test(arguments: ["/Users/someone", "/Users/someone/Library", "/Users/someone/Library/Caches",
                      "/Users/someone/Downloads", "/Users/other/Library/Caches/x", "/System/Library/x",
                      "/Users/someone/../other/x", "/Users/someonesecret/x"])
    func protectedOrOutsideIsRefused(_ path: String) {
        #expect(!PathGuard.isAllowed(URL(fileURLWithPath: path), home: home))
    }

    @Test func skipListMatchesInsideButNotSiblings() {
        let skip = SkipList(["/Users/someone/Library/Caches/com.x"])
        #expect(skip.matches(URL(fileURLWithPath: "/Users/someone/Library/Caches/com.x")))
        #expect(skip.matches(URL(fileURLWithPath: "/Users/someone/Library/Caches/com.x/a")))
        #expect(!skip.matches(URL(fileURLWithPath: "/Users/someone/Library/Caches/com.xy")))
    }
}

@Suite struct CleanerTests {
    @Test func movesOnlyTickedItemsAndUndoPutsThemBack() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let trash = FolderTrash(folder: f.root.appending(path: "Trash"))
        let cleaner = Cleaner(home: f.home, trash: trash)
        let a = f.home.appending(path: "Library/Logs/Example")
        let outcome = cleaner.moveToTrash([(a, 5_000)])
        #expect(outcome.moved.count == 1)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: outcome.moved[0].inTrash.path))
        #expect(FileManager.default.fileExists(atPath: f.home.appending(path: "Downloads/keep.pdf").path))

        let undo = cleaner.undo(outcome.moved)
        #expect(undo.restored.count == 1)
        #expect(FileManager.default.fileExists(atPath: a.appending(path: "x.log").path))
    }

    @Test func refusesPathsOutsideHome() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cleaner = Cleaner(home: f.home, trash: FolderTrash(folder: f.root.appending(path: "Trash")))
        let outcome = cleaner.moveToTrash([(f.outside.appending(path: "precious.bin"), 1)])
        #expect(outcome.moved.isEmpty)
        #expect(outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: f.outside.appending(path: "precious.bin").path))
    }

    @Test func movingASymlinkLeavesItsTarget() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cleaner = Cleaner(home: f.home, trash: FolderTrash(folder: f.root.appending(path: "Trash")))
        _ = cleaner.moveToTrash([(f.home.appending(path: "Library/Caches/link-out"), 1)])
        #expect(FileManager.default.fileExists(atPath: f.outside.appending(path: "precious.bin").path))
    }

    @Test func missingItemsAreReportedNotRetried() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cleaner = Cleaner(home: f.home, trash: FolderTrash(folder: f.root.appending(path: "Trash")))
        let outcome = cleaner.moveToTrash([(f.home.appending(path: "Library/Caches/nope"), 1)])
        #expect(outcome.failed.count == 1)
    }

    @Test func undoSkipsWhenOriginalPathIsTaken() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cleaner = Cleaner(home: f.home, trash: FolderTrash(folder: f.root.appending(path: "Trash")))
        let target = f.home.appending(path: "Downloads/movie.mp4.crdownload")
        let outcome = cleaner.moveToTrash([(target, 1)])
        try f.write("Downloads/movie.mp4.crdownload", bytes: 10)
        let undo = cleaner.undo(outcome.moved)
        #expect(undo.restored.isEmpty)
        #expect(undo.skipped.count == 1)
    }
}

@Suite struct AppGuardTests {
    @Test func appsInApplicationsFoldersAreRemovable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let apps = f.root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: apps.appending(path: "Tool.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps.appending(path: "Vendor/Helper.app/Contents"), withIntermediateDirectories: true)
        #expect(AppGuard.isRemovableApp(apps.appending(path: "Tool.app"), home: f.home, applications: [apps]))
        #expect(AppGuard.isRemovableApp(apps.appending(path: "Vendor/Helper.app"), home: f.home, applications: [apps]))
        #expect(!AppGuard.isRemovableApp(apps.appending(path: "Vendor"), home: f.home, applications: [apps]))
        #expect(!AppGuard.isRemovableApp(f.outside.appending(path: "Tool.app"), home: f.home, applications: [apps]))
    }

    @Test func appleAppsAreNeverRemovable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let apps = f.root.appending(path: "Applications")
        let contents = apps.appending(path: "Pages.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.apple.iWork.Pages", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        #expect(!AppGuard.isRemovableApp(apps.appending(path: "Pages.app"), home: f.home, applications: [apps]))
    }

    @Test func cleanerMovesAnAppOnlyWhenMarkedAsOne() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let apps = f.root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: apps.appending(path: "Tool.app/Contents"), withIntermediateDirectories: true)
        let cleaner = Cleaner(home: f.home, trash: FolderTrash(folder: f.root.appending(path: "Trash")), applications: [apps])
        #expect(cleaner.moveToTrash([CleanRequest(url: apps.appending(path: "Tool.app"), size: 1)]).moved.isEmpty)
        #expect(cleaner.moveToTrash([CleanRequest(url: apps.appending(path: "Tool.app"), size: 1, isAppBundle: true)]).moved.count == 1)
    }
}

@Suite struct LargeFileTests {
    @Test func findsBigFilesOutsideLibraryAndCountsPackagesOnce() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("Movies/Big.app/Contents/MacOS/a", bytes: 20_000)
        try f.write("Movies/Big.app/Contents/Resources/b", bytes: 20_000)
        let files = await LargeFileFinder(root: f.home, home: f.home, minSize: 25_000).run()
        let names = Set(files.map(\.name))
        #expect(names.contains("report.pages"))
        #expect(names.contains("keep.pdf"))
        #expect(names.contains("Big.app"))
        #expect(!names.contains("a") && !names.contains("b"))
        #expect(!names.contains("out.o"), "~/Library is left to Smart Scan")
        #expect(files.first { $0.name == "Big.app" }?.isPackage == true)
    }

    @Test func skippedFoldersAreLeftAlone() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let skip = SkipList([f.home.appending(path: "Documents").path])
        let files = await LargeFileFinder(root: f.home, home: f.home, minSize: 25_000, skipped: skip).run()
        #expect(!files.contains { $0.name == "report.pages" })
    }

    @Test func filterBySizeAgeAndKind() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-86_400 * 500)
        let recent = now.addingTimeInterval(-86_400 * 10)
        let u = URL(fileURLWithPath: "/x")
        let files = [
            LargeFile(url: u.appending(path: "a.mov"), size: 2_000_000_000, kind: .video, lastOpened: old),
            LargeFile(url: u.appending(path: "b.zip"), size: 600_000_000, kind: .archive, lastOpened: recent),
            LargeFile(url: u.appending(path: "c.bin"), size: 150_000_000, kind: .other, lastOpened: nil),
        ]
        #expect(LargeFileFilter(minSize: 500_000_000).apply(files, now: now).map(\.name) == ["a.mov", "b.zip"])
        #expect(LargeFileFilter(minSize: 100_000_000, age: .oneYear).apply(files, now: now).map(\.name) == ["a.mov", "c.bin"])
        #expect(LargeFileFilter(minSize: 100_000_000, kind: .archive).apply(files, now: now).map(\.name) == ["b.zip"])
    }

    @Test func kindsComeFromContentType() {
        #expect(FileKind.of(.quickTimeMovie) == .video)
        #expect(FileKind.of(.zip) == .archive)
        #expect(FileKind.of(UTType(filenameExtension: "dmg")) == .diskImage)
        #expect(FileKind.of(.pdf) == .other)
    }
}

@Suite struct DiskMapTests {
    @Test func treemapKeepsEachShareOfTheAreaInsideTheRect() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let sizes: [Double] = [50, 25, 12, 8, 3, 2]
        let blocks = Treemap.layout(sizes, in: rect)
        #expect(blocks.count == sizes.count)
        let total = sizes.reduce(0, +)
        for b in blocks {
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(b.rect))
            let share = Double(b.rect.width * b.rect.height) / Double(rect.width * rect.height)
            #expect(abs(share - sizes[b.index] / total) < 0.001)
        }
    }

    @Test func hardLinksCountOnceAndSizesAddUp() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let docs = f.home.appending(path: "Documents")
        try FileManager.default.linkItem(at: docs.appending(path: "report.pages"), to: docs.appending(path: "link.pages"))
        guard let tree = await DiskMapper(root: docs).run() else { Issue.record("no tree"); return }
        let files = tree.children.filter { !$0.isDirectory }
        #expect(files.filter { $0.size > 0 }.count == 1, "the second link adds nothing")
        #expect(tree.size >= tree.children.reduce(0) { $0 + $1.size })
    }

    @Test func foldsSmallItemsAndRemovesPaths() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        guard let tree = await DiskMapper(root: f.home, keepChildren: 2).run() else { Issue.record("no tree"); return }
        #expect(tree.children.last?.isOther == true)
        let downloads = f.home.appending(path: "Downloads/keep.pdf").path
        let smaller = tree.removing([downloads])
        #expect((smaller?.size ?? 0) < tree.size)
    }
}

@Suite struct LeftoverTests {
    func makeApp(_ f: Fixture, id: String = "com.example.fake", name: String = "FakeApp") throws -> InstalledApp {
        let contents = f.home.appending(path: "Applications/\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        try f.write("Library/Application Support/\(id)/data.db", bytes: 4_000)
        try f.write("Library/Preferences/\(id).plist", bytes: 100)
        try f.write("Library/Containers/\(id)/Data/x", bytes: 2_000)
        try f.write("Library/Saved Application State/\(id).savedState/w", bytes: 100)
        try f.write("Library/Application Support/\(name)/cache", bytes: 1_000)
        try f.write("Library/Application Support/\(id)-other/z", bytes: 100)
        return AppCatalog.app(at: f.home.appending(path: "Applications/\(name).app"), home: f.home,
                              folders: [f.home.appending(path: "Applications")])
    }

    @Test func findsLeftoversByBundleIDAndMarksNameMatchesPossible() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let app = try makeApp(f)
        #expect(app.bundleID == "com.example.fake")
        #expect(!app.isLocked)
        let found = LeftoverFinder(home: f.home).leftovers(for: app)
        let byName = Dictionary(found.map { ("\($0.location)/\($0.url.lastPathComponent)", $0) }, uniquingKeysWith: { a, _ in a })
            .reduce(into: [String: Leftover]()) { $0[$1.key] = $1.value; $0[String($1.key.split(separator: "/").last!)] = $1.value }
        #expect(byName["Containers/com.example.fake"]?.isCertain == true)
        #expect(byName["Application Support/com.example.fake"]?.isCertain == true)
        #expect(byName["com.example.fake.plist"]?.isCertain == true)
        #expect(byName["com.example.fake.savedState"]?.isCertain == true)
        #expect(byName["FakeApp"]?.isCertain == false, "a name-only match is a possible match")
        #expect(byName["com.example.fake-other"] == nil, "a similar id is not a match")
    }

    @Test func listsAppsInApplicationsFolders() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try makeApp(f)
        let apps = AppCatalog.installedApps(in: [f.home.appending(path: "Applications")], home: f.home)
        #expect(apps.map(\.name) == ["FakeApp"])
    }

    @Test func orphansAreIDsNoInstalledAppHas() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try makeApp(f)
        try f.write("Library/Containers/com.gone.app/Data/x", bytes: 3_000)
        try f.write("Library/Containers/com.apple.Notes/Data/x", bytes: 3_000)
        try f.write("Library/Preferences/com.example.fake.helper.plist", bytes: 100)
        let installed: Set<String> = ["com.example.fake"]
        let orphans = LeftoverFinder(home: f.home).orphans { LeftoverFinder.isOwned($0, by: installed) }
        let owners = Set(orphans.compactMap(\.owner))
        #expect(owners.contains("com.gone.app"))
        #expect(!owners.contains("com.apple.Notes"), "Apple's ids are never listed")
        #expect(!owners.contains("com.example.fake.helper"), "a helper of an installed app is owned")
        #expect(!owners.contains("com.example.fake"))
    }

    @Test func bundleIDShape() {
        #expect(LeftoverFinder.looksLikeBundleID("com.vendor.app"))
        #expect(!LeftoverFinder.looksLikeBundleID("Slack"))
        #expect(!LeftoverFinder.looksLikeBundleID("com.vendor"))
        #expect(!LeftoverFinder.looksLikeBundleID("my folder.v2.old"))
    }
}

@Suite struct LaunchItemTests {
    func writeAgent(_ f: Fixture, label: String, program: String, disabled: Bool = false) throws {
        let dir = f.home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = ["Label": label, "ProgramArguments": [program, "--login"], "RunAtLoad": true]
        if disabled { plist["Disabled"] = true }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appending(path: "\(label).plist"))
    }

    @Test func parsesAgentsAndFindsTheirApps() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try writeAgent(f, label: "com.example.fake.helper", program: "/usr/local/bin/fakehelper")
        try writeAgent(f, label: "org.other.updater", program: "/Applications/Other.app/Contents/MacOS/updater", disabled: true)
        let items = LaunchItems.load(folder: f.home.appending(path: "Library/LaunchAgents"), scope: .user)
        #expect(items.map(\.label) == ["com.example.fake.helper", "org.other.updater"])
        #expect(items[1].disabledInPlist)
        #expect(items[1].programApp?.path == "/Applications/Other.app")
        let apps = [
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Fake.app"), name: "Fake", bundleID: "com.example.fake", version: nil, teamID: nil, isLocked: false),
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Other.app"), name: "Other", bundleID: "org.other.app", version: nil, teamID: nil, isLocked: false),
        ]
        #expect(LaunchItems.owner(of: items[0], apps: apps)?.name == "Fake", "matched by label")
        #expect(LaunchItems.owner(of: items[1], apps: apps)?.name == "Other", "matched by program path")
    }

    @Test func fakeControlTurnsUserItemsOffAndRefusesSystemOnes() throws {
        let control = FakeLaunchControl()
        let user = LaunchItem(label: "a.b.c", plist: URL(fileURLWithPath: "/x.plist"), program: nil, scope: .user, disabledInPlist: false)
        let system = LaunchItem(label: "d.e.f", plist: URL(fileURLWithPath: "/y.plist"), program: nil, scope: .systemDaemon, disabledInPlist: false)
        try control.turnOff(user)
        #expect(control.disabledLabels() == ["a.b.c"])
        try control.turnOn(user)
        #expect(control.disabledLabels().isEmpty)
        #expect(throws: LaunchControlError.self) { try control.turnOff(system) }
    }
}

@Suite struct ScanCategoryTests {
    @Test func onlyChosenCategoriesRun() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (items, _) = await Scanner(home: f.home, categories: [.logs]).run()
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.category == .logs })
    }
}

// MARK: - Version two modules

@Suite struct SystemStatsTests {
    @Test func cpuUsageFromTickDeltas() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 150, system: 75, idle: 1025, nice: 0)
        #expect(abs(CPUTicks.usage(from: a, to: b) - 30) < 0.001)
        #expect(CPUTicks.usage(from: b, to: a) == 0, "going backwards reads as zero")
    }

    @Test func memoryUsedNeverExceedsTotal() {
        let m = MemoryStats.from(pageSize: 16_384, total: 8 << 30, active: 300_000, wired: 200_000, compressed: 100_000, inactive: 0, free: 0)
        #expect(m.used == 8 << 30)
        let n = MemoryStats.from(pageSize: 16_384, total: 16 << 30, active: 100_000, wired: 50_000, compressed: 10_000, inactive: 5, free: 5)
        #expect(n.used == 160_000 * 16_384)
        #expect(n.usedFraction > 0 && n.usedFraction < 1)
    }

    @Test func liveSamplesAreSane() throws {
        let t1 = try #require(CPUTicks.read())
        let t2 = try #require(CPUTicks.read())
        #expect((0...100).contains(CPUTicks.usage(from: t1, to: t2)))
        let m = try #require(MemoryStats.read())
        #expect(m.used > 0 && m.used <= m.total)
        #expect(Uptime.seconds() > 0)
        #expect(!ProcessSample.all().isEmpty)
    }

    @Test func networkRateIgnoresResets() {
        let a = NetworkCounters(received: 1_000, sent: 500)
        let b = NetworkCounters(received: 3_000, sent: 400)
        let r = NetworkCounters.rate(from: a, to: b, seconds: 2)
        #expect(r.down == 1_000)
        #expect(r.up == 0)
    }

    @Test func batteryHealthFromCapacities() {
        let info = BatteryInfo.parse(["CycleCount": 312, "DesignCapacity": 5_000, "AppleRawMaxCapacity": 4_400,
                                      "CurrentCapacity": 80, "MaxCapacity": 100, "IsCharging": true, "ExternalConnected": true])
        #expect(info.healthPercent == 88)
        #expect(info.chargePercent == 80)
        #expect(info.cycleCount == 312)
        #expect(info.isCharging)
    }

    @Test func batteryCapacitiesInNestedBatteryData() {
        // The shape on Apple silicon: percent at the top, mAh figures nested.
        let info = BatteryInfo.parse(["CycleCount": 61, "CurrentCapacity": 23, "MaxCapacity": 100,
                                      "BatteryData": ["DesignCapacity": 6_249, "FullChargeCapacity": 5_997]])
        #expect(info.healthPercent == 96)
        #expect(info.chargePercent == 23)
    }

    @Test func liveBatteryHasHealthWhenPresent() {
        guard let b = BatteryInfo.read() else { return }  // desktops have none
        #expect(b.healthPercent != nil)
        #expect((1...150).contains(b.healthPercent ?? 0))
    }
}

@Suite struct PermissionTests {
    @Test func readsAllowedAndDeniedGrants() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let db = f.root.appending(path: "TCC.db")
        try makeTCC(db, rows: [("kTCCServiceCamera", "us.zoom.xos", 0, 2), ("kTCCServiceMicrophone", "us.zoom.xos", 0, 0),
                               ("kTCCServiceScreenCapture", "/usr/local/bin/tool", 1, 2), ("kTCCServiceUnknownThing", "x.y.z", 0, 2)])
        let grants = try TCCReader.read(db)
        #expect(grants.count == 3, "unknown services are skipped")
        #expect(grants.first { $0.service == .camera }?.allowed == true)
        #expect(grants.first { $0.service == .microphone }?.allowed == false)
        #expect(grants.first { $0.service == .screenCapture }?.isPath == true)
    }

    @Test func missingDatabaseThrows() {
        #expect(throws: TCCReader.ReadError.self) { try TCCReader.read(URL(fileURLWithPath: "/nonexistent/TCC.db")) }
    }
}

/// A TCC-shaped database for tests.
func makeTCC(_ url: URL, rows: [(String, String, Int, Int)]) throws {
    let sql = (["CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, auth_reason INTEGER, auth_version INTEGER, last_modified INTEGER);"]
        + rows.map { "INSERT INTO access VALUES ('\($0.0)','\($0.1)',\($0.2),\($0.3),0,1,1700000000);" }).joined(separator: "\n")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [url.path, sql]
    try p.run()
    p.waitUntilExit()
}

@Suite struct UpdateTests {
    @Test func versionsCompareNumerically() {
        #expect(Version.isNewer("1.10", than: "1.9"))
        #expect(!Version.isNewer("2.0", than: "2"))
        #expect(Version.isNewer("4.41.105", than: "4.41.98"))
        #expect(!Version.isNewer("1.2", than: "1.2.1"))
    }

    @Test func appcastNewestItem() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>1.9</title><enclosure url="a" sparkle:version="190" sparkle:shortVersionString="1.9"/></item>
        <item><title>1.10</title><sparkle:shortVersionString>1.10</sparkle:shortVersionString><enclosure url="b" sparkle:version="200"/></item>
        </channel></rss>
        """
        #expect(AppcastParser.newest(in: Data(xml.utf8))?.version == "1.10")
    }

    @Test func updateSourceFromInfoPlist() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let app = f.root.appending(path: "Tool.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.0", "SUFeedURL": "https://example.com/appcast.xml"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        #expect(UpdateSource.of(app: app) == UpdateSource(kind: .sparkle(URL(string: "https://example.com/appcast.xml")!), currentVersion: "1.0"))
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data([1]).write(to: app.appending(path: "Contents/_MASReceipt/receipt"))
        #expect(UpdateSource.of(app: app).kind == .appStore)
    }
}

@Suite struct PrivacyTests {
    @Test func findsChromiumProfilesAndNeverFirefoxHistory() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let chrome = "Library/Application Support/Google/Chrome"
        try f.write("\(chrome)/Default/History", bytes: 5_000)
        try f.write("\(chrome)/Default/Cookies", bytes: 2_000)
        try f.write("\(chrome)/Profile 1/History", bytes: 3_000)
        try f.write("\(chrome)/System Profile/History", bytes: 3_000)
        try f.write("Library/Caches/Google/Chrome/Default/Cache/data_0", bytes: 9_000)
        try f.write("Library/Application Support/Firefox/Profiles/abc.default-release/places.sqlite", bytes: 9_000)
        try f.write("Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite", bytes: 1_000)
        let items = BrowserDataFinder(home: f.home).find()
        let chromeItems = items.filter { $0.browser == "Google Chrome" }
        #expect(Set(chromeItems.map(\.profile)) == ["Default Profile", "Profile 1"])
        #expect(chromeItems.contains { $0.kind == .cache && $0.profile == "Default Profile" })
        let firefox = items.filter { $0.browser == "Firefox" }
        #expect(firefox.map(\.kind) == [.cookies])
        #expect(!items.flatMap(\.urls).contains { $0.lastPathComponent == "places.sqlite" })
    }

    @Test func findsRecentItemLists() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let base = "Library/Application Support/com.apple.sharedfilelist"
        try f.write("\(base)/com.apple.LSSharedFileList.RecentDocuments.sfl3", bytes: 100)
        try f.write("\(base)/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.textedit.sfl3", bytes: 100)
        let lists = RecentItemsFinder.find(home: f.home)
        #expect(lists.map(\.title) == ["Recent Documents", "Recent Documents in com.apple.textedit"])
    }

    @Test func parsesLaunchctlList() {
        let out = "PID\tStatus\tLabel\n-\t0\tcom.vendor.idle\n512\t0\tcom.vendor.agent\n88\t0\tcom.apple.Finder\n901\t0\tapplication.com.tinyspeck.slackmacgap.1234\n"
        let jobs = LaunchJob.parse(out)
        #expect(jobs.count == 4)
        #expect(!jobs[0].isRunning)
        #expect(jobs[1].pid == 512)
        #expect(jobs[2].isApple)
        #expect(jobs[3].applicationBundleID == "com.tinyspeck.slackmacgap")
        #expect(!LaunchJob.list().isEmpty, "the real list is readable")
    }
}

@Suite struct UnusedRuleTests {
    @Test func unusedNeedsAnOldDate() {
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let before = cutoff.addingTimeInterval(-10), after = cutoff.addingTimeInterval(10)
        #expect(UnusedRule.isUnused(lastUsed: before, added: nil, cutoff: cutoff))
        #expect(!UnusedRule.isUnused(lastUsed: after, added: before, cutoff: cutoff))
        #expect(UnusedRule.isUnused(lastUsed: nil, added: before, cutoff: cutoff))
        #expect(!UnusedRule.isUnused(lastUsed: nil, added: after, cutoff: cutoff), "a new app has had no chance yet")
        #expect(!UnusedRule.isUnused(lastUsed: nil, added: nil, cutoff: cutoff))
    }
}

@Suite struct ProtectedFolderTests {
    @Test func findsChromiumCacheWhenTheDataFolderIsBlocked() throws {
        let f = try Fixture()
        let support = f.home.appending(path: "Library/Application Support/BraveSoftware/Brave-Browser")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path); f.cleanup() }
        try f.write("Library/Application Support/BraveSoftware/Brave-Browser/Default/History", bytes: 1_000)
        try f.write("Library/Caches/BraveSoftware/Brave-Browser/Default/Cache/data_0", bytes: 8_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: support.path)
        let finder = BrowserDataFinder(home: f.home)
        let items = finder.find()
        #expect(items.contains { $0.browser == "Brave" && $0.kind == .cache && $0.profile == "Default Profile" })
        #expect(finder.blockedBrowsers() == ["Brave"])
    }
}

@Suite struct SettingsLogicTests {
    @Test func lowSpaceAlertsOnceUntilSpaceComesBack() {
        var alert = LowSpaceAlert(limit: 10_000, margin: 1_000)
        let results = [20_000, 9_000, 8_000, 10_500, 12_000, 9_500].map { alert.shouldAlert(available: $0) }
        // Quiet above the limit, once below it, quiet inside the margin, again after space came back.
        #expect(results == [false, true, false, false, false, true])
        var off = LowSpaceAlert(limit: 0)
        let offResult = off.shouldAlert(available: 1)
        #expect(!offResult)
    }

    @Test func historyRetentionCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(HistoryRetention.cutoff(days: 0, now: now) == nil)
        #expect(HistoryRetention.cutoff(days: 30, now: now)! < now)
    }
}

// MARK: - Version three: fixes, developer cleanup, holding area, duplicates, updates

extension Fixture {
    /// Sets a file's modification date `days` ago.
    func age(_ path: String, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86_400)],
                                              ofItemAtPath: home.appending(path: path).path)
    }
}

@Suite struct DeveloperCleanupTests {
    @Test func freshLogsAreLeftAlone() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("Library/Logs/Fresh/today.log", bytes: 2_000)
        let (items, _) = await Scanner(home: f.home, categories: [.logs]).run()
        let names = Set(items.map(\.name))
        #expect(names.contains("Example"), "a log untouched for 30 days is offered")
        #expect(!names.contains("Fresh"), "a log written today is not")
    }

    @Test func packageCachesHaveTheirOwnCategory() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("Library/Caches/Homebrew/downloads/x.tar.gz", bytes: 9_000)
        try f.write(".npm/_cacache/content/a", bytes: 9_000)
        try f.write(".npm/.npmrc-backup", bytes: 100)
        try f.write(".gradle/caches/x.jar", bytes: 9_000)
        try f.write(".gradle/gradle.properties", bytes: 100)
        let (items, _) = await Scanner(home: f.home, categories: [.appCaches, .packageCaches]).run()
        let caches = Set(items.filter { $0.category == .appCaches }.map(\.name))
        let packages = Set(items.filter { $0.category == .packageCaches }.map(\.name))
        #expect(packages == ["Homebrew", "_cacache", "caches"])
        #expect(!caches.contains("Homebrew"), "never counted twice")
        #expect(!ScanCategory.packageCaches.isRecommended)
    }

    @Test func oldProjectDependenciesOnly() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("Developer/old-site/package.json", bytes: 200)
        try f.write("Developer/old-site/src/index.js", bytes: 200)
        try f.write("Developer/old-site/node_modules/left-pad/index.js", bytes: 9_000)
        try f.age("Developer/old-site/package.json", days: 200)
        try f.age("Developer/old-site/src/index.js", days: 200)
        try f.write("Developer/new-site/package.json", bytes: 200)
        try f.write("Developer/new-site/node_modules/react/index.js", bytes: 9_000)
        try f.write("Developer/stray/node_modules/x.js", bytes: 9_000)   // no package.json: not a project
        try f.write("Developer/OldKit/Package.swift", bytes: 200)
        try f.age("Developer/OldKit/Package.swift", days: 365)
        try f.write("Developer/OldKit/.build/debug/OldKit.o", bytes: 9_000)
        let (items, _) = await Scanner(home: f.home, categories: [.projectBuilds]).run()
        let paths = Set(items.map { PathGuard.relativePath(of: $0.url, in: f.home) ?? "" })
        #expect(paths == ["Developer/old-site/node_modules", "Developer/OldKit/.build"], "\(paths)")
    }

    @Test func archivesAreFoundAndNotTicked() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("Library/Developer/Xcode/Archives/2025-01-02/App.xcarchive/Info.plist", bytes: 3_000)
        let (items, _) = await Scanner(home: f.home, categories: [.xcodeArchives]).run()
        #expect(items.map(\.name) == ["2025-01-02"])
        #expect(!ScanCategory.xcodeArchives.isRecommended)
    }

    @Test func cachesOfOpenAppsAreRecognised() {
        let running = [RunningApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"), RunningApp(bundleID: "org.mozilla.firefox", name: "Firefox")]
        #expect(CacheOwner.runningOwner(ofCacheNamed: "com.tinyspeck.slackmacgap", running: running)?.name == "Slack")
        #expect(CacheOwner.runningOwner(ofCacheNamed: "com.tinyspeck.slackmacgap.ShipIt", running: running)?.name == "Slack")
        #expect(CacheOwner.runningOwner(ofCacheNamed: "Firefox", running: running)?.name == "Firefox")
        #expect(CacheOwner.runningOwner(ofCacheNamed: "com.tinyspeck.slackmacgapX", running: running) == nil)
        #expect(CacheOwner.runningOwner(ofCacheNamed: "com.google.Chrome", running: running) == nil)
    }

    @Test func processOutputNeverBlocksOnAFullPipe() throws {
        // 200 KB on standard error is more than a pipe holds.
        let result = try ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero >&2; echo ok"])
        #expect(result.status == 0)
        #expect(result.output == "ok\n")
        #expect(result.error.utf8.count == 200_000)
    }
}

@Suite struct HoldingAreaTests {
    @Test func holdsPutsBackAndDeletes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let area = HoldingArea(folder: f.root.appending(path: "Holding"))
        let cleaner = Cleaner(home: f.home, trash: area)
        let log = f.home.appending(path: "Library/Logs/Example")
        let cache = f.home.appending(path: "Library/Caches/com.example.app")
        let outcome = cleaner.moveToTrash([(log, 5_000), (cache, 40_000)])
        #expect(outcome.moved.count == 2)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(outcome.moved.allSatisfy { area.contains($0.inTrash) })

        let held = area.items()
        #expect(held.count == 2)
        #expect(Set(held.compactMap(\.original?.path)) == [log.path, cache.path])

        // Put one back, then tidy leaves no empty batch behind.
        let back = cleaner.undo([outcome.moved[0]])
        #expect(back.restored.count == 1)
        #expect(FileManager.default.fileExists(atPath: log.appending(path: "x.log").path))
        area.tidy()
        #expect(area.items().count == 1)
        let batches = try FileManager.default.contentsOfDirectory(atPath: area.folder.path)
        #expect(batches.count == 1)

        // Purge counts from when items were held.
        #expect(area.purge(heldBefore: Date.now.addingTimeInterval(-86_400)).deleted.isEmpty)
        let purged = area.purge(heldBefore: Date.now.addingTimeInterval(60))
        #expect(purged.deleted.count == 1)
        #expect(area.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func deletesOnlyItsOwnBatches() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let area = HoldingArea(folder: f.root.appending(path: "Holding"))
        let keep = f.home.appending(path: "Downloads/keep.pdf")
        let fake = HeldItem(batch: f.home.appending(path: "Downloads"), location: keep, original: nil, heldAt: .distantPast, size: 1)
        let outcome = area.delete([fake])
        #expect(outcome.deleted.isEmpty && outcome.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func deletesReadOnlyFolders() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let area = HoldingArea(folder: f.root.appending(path: "Holding"))
        try f.write("Library/Caches/locked/inner/file.bin", bytes: 1_000)
        let locked = f.home.appending(path: "Library/Caches/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.appending(path: "inner").path)
        _ = try area.moveToTrash(locked)
        #expect(area.delete(area.items()).deleted.count == 1)
        #expect(area.items().isEmpty)
    }
}

@Suite struct DuplicateTests {
    @Test func findsSameContentsOnly() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = Data((0..<300_000).map { UInt8($0 % 251) })
        var b = a; b[150_000] ^= 0xFF   // same size, same head and tail, different middle
        func put(_ path: String, _ data: Data) throws {
            let url = f.home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try put("Documents/Photos/trip.mov", a)
        try put("Downloads/trip.mov", a)
        try put("Desktop/trip copy.mov", a)
        try put("Documents/other.mov", b)
        try put("Library/Caches/trip.mov", a)   // ~/Library is never looked through
        try FileManager.default.linkItem(at: f.home.appending(path: "Documents/Photos/trip.mov"),
                                         to: f.home.appending(path: "Documents/hardlink.mov"))
        let groups = await DuplicateFinder(root: f.home, home: f.home, minSize: 100_000).run()
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        let names = group.files.map { PathGuard.relativePath(of: $0.url, in: f.home) ?? "" }
        #expect(names.count == 3, "a hard link and ~/Library are left out: \(names)")
        #expect(names.first?.hasPrefix("Documents/") == true, "the copy outside Downloads and Desktop is kept")
        #expect(group.extraBytes == 600_000)
        #expect(group.removing(Set(group.files.dropFirst().map(\.id))) == nil, "one copy alone is no longer a group")
    }

    @Test func smallFilesAreSkipped() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.write("Documents/a.txt", bytes: 500)
        try f.write("Documents/b.txt", bytes: 500)
        #expect(await DuplicateFinder(root: f.home, home: f.home, minSize: 100_000).run().isEmpty)
    }
}

@Suite struct UpdateSourceTests {
    func app(_ f: Fixture, _ name: String, plist: [String: Any]) throws -> URL {
        let url = f.home.appending(path: "Applications/\(name).app")
        try FileManager.default.createDirectory(at: url.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }

    @Test func readsElectronUpdaterFiles() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let generic = try app(f, "Gen", plist: ["CFBundleShortVersionString": "1.0"])
        try "provider: generic\nurl: 'https://updates.example.com/mac'\n".write(to: generic.appending(path: "Contents/Resources/app-update.yml"), atomically: true, encoding: .utf8)
        #expect(UpdateSource.of(app: generic).kind == .electron(URL(string: "https://updates.example.com/mac")!))
        #expect(UpdateSource.Kind.electron(URL(string: "https://updates.example.com/mac")!).requestURL?.absoluteString == "https://updates.example.com/mac/latest-mac.yml")
        let gh = try app(f, "Hub", plist: ["CFBundleShortVersionString": "1.0"])
        try "owner: acme\nrepo: hub-desktop\nprovider: github\n".write(to: gh.appending(path: "Contents/Resources/app-update.yml"), atomically: true, encoding: .utf8)
        #expect(UpdateSource.of(app: gh).kind == .github(owner: "acme", repo: "hub-desktop"))
        let plain = try app(f, "Plain", plist: ["CFBundleShortVersionString": "1.0"])
        try "provider: generic\nurl: http://insecure.example.com\n".write(to: plain.appending(path: "Contents/Resources/app-update.yml"), atomically: true, encoding: .utf8)
        #expect(UpdateSource.of(app: plain).kind == .unknown, "never plain http")
    }

    @Test func readsNewestVersions() {
        #expect(UpdateSource.Kind.electron(URL(string: "https://x.com")!).newestVersion(in: Data("version: 2.3.1\nfiles:\n  - url: a.zip\n".utf8)) == "2.3.1")
        #expect(UpdateSource.Kind.github(owner: "a", repo: "b").newestVersion(in: Data(#"{"tag_name":"v4.0.2"}"#.utf8)) == "4.0.2")
        let brew = UpdateSource.Kind.homebrew(token: "foo", installed: "1.2,300")
        #expect(brew.newestVersion(in: Data(#"{"version":"1.3,310"}"#.utf8)) == "1.3,310")
        #expect(brew.newestVersion(in: Data(#"{"version":"latest"}"#.utf8)) == nil)
        #expect(brew.installedVersion == "1.2,300")
        #expect(Version.isNewer("1.3,310", than: "1.2,300"))
    }

    @Test func findsHomebrewCasks() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let room = f.root.appending(path: "Caskroom")
        let json = room.appending(path: "visual-studio-code/.metadata/1.95.3/20241120.1/Casks/visual-studio-code.json")
        try FileManager.default.createDirectory(at: json.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: room.appending(path: "visual-studio-code/1.95.3"), withIntermediateDirectories: true)
        try Data(#"{"artifacts":[{"app":["Visual Studio Code.app"]},{"zap":[{"trash":["~/Library/Caches/Evil.app"]}]}]}"#.utf8).write(to: json)
        let rb = room.appending(path: "rectangle/.metadata/0.84/20240101.1/Casks/rectangle.rb")
        try FileManager.default.createDirectory(at: rb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: room.appending(path: "rectangle/0.84"), withIntermediateDirectories: true)
        try "cask \"rectangle\" do\n  version \"0.84\"\n  app \"Rectangle.app\"\nend\n".write(to: rb, atomically: true, encoding: .utf8)
        let index = HomebrewCasks.index(caskrooms: [room])
        #expect(index["Visual Studio Code.app"] == CaskInfo(token: "visual-studio-code", version: "1.95.3"))
        #expect(index["Rectangle.app"]?.token == "rectangle")
        #expect(index["Evil.app"] == nil, "zap paths are not apps")
        #expect(CaskInfo(token: "rectangle", version: "0.84").upgradeCommand == "brew upgrade --cask rectangle")

        let vsc = try app(f, "Visual Studio Code", plist: ["CFBundleShortVersionString": "1.95.3"])
        #expect(UpdateSource.of(app: vsc, casks: index).kind == .homebrew(token: "visual-studio-code", installed: "1.95.3"))
    }
}
