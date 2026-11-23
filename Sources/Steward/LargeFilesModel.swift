import AppKit
import Foundation
import Observation
import StewardKit

/// State for Large & Old Files. Scans once at the smallest size and filters
/// in memory, so changing a filter is instant; choosing a folder rescans.
@Observable
final class LargeFilesModel {
    let home: URL
    var root: URL
    var files: [LargeFile] = []
    var scanning = false
    var currentFolder: URL?
    var hasScanned = false

    var threshold: Int64 = LargeFilesModel.defaultThreshold
    var age: FileAge = Prefs.largeAge
    var kind: FileKind?

    var ticked: Set<String> = []
    var selection: Set<String> = []
    var preview: URL?

    /// The smallest size the scan collects. The self-test lowers it.
    var scanMinSize: Int64 = LargeFileFilter.thresholds[0]

    private var task: Task<Void, Never>?
    /// Files that moved to the Trash, so Undo can show them again.
    private var removedCache: [String: LargeFile] = [:]

    init(home: URL) {
        self.home = home
        self.root = home
    }

    static var defaultThreshold: Int64 {
        let saved = Int64(ScanSettings.store.integer(forKey: "largeFiles.threshold"))
        return LargeFileFilter.thresholds.contains(saved) ? saved : LargeFileFilter.thresholds[0]
    }

    var filter: LargeFileFilter { LargeFileFilter(minSize: max(threshold, scanMinSize), age: age, kind: kind) }
    var visible: [LargeFile] { filter.apply(files) }
    var tickedVisible: [LargeFile] { visible.filter { ticked.contains($0.id) } }
    var selectedURLs: [URL] { visible.filter { selection.contains($0.id) }.map(\.url) }

    func scan(skipped: SkipList) {
        task?.cancel()
        files = []
        ticked = []
        selection = []
        scanning = true
        hasScanned = true
        let finder = LargeFileFinder(root: root, home: home, minSize: scanMinSize, skipped: skipped)
        task = Task {
            for await event in finder.events() {
                if Task.isCancelled { break }
                switch event {
                case .folder(let url): currentFolder = url
                case .found(let file): files.append(file)
                }
            }
            scanning = false
            currentFolder = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        scanning = false
        currentFolder = nil
    }

    func chooseFolder(skipped: SkipList) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Choose"
        panel.message = "Choose a folder to look through for large files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        scan(skipped: skipped)
    }

    func toggle(_ file: LargeFile) {
        if ticked.contains(file.id) { ticked.remove(file.id) } else { ticked.insert(file.id) }
    }

    func reason(for file: LargeFile) -> String {
        if age != .any, let opened = file.lastOpened {
            return "Not opened since \(opened.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Large file, \(file.kind.rowTitle.lowercased())"
    }

    func reviewSession() -> ReviewSession? {
        let rows = tickedVisible.map {
            Candidate(url: $0.url, size: $0.size, reason: reason(for: $0),
                      group: age == .any ? "Large File" : "Old File")
        }
        return rows.isEmpty ? nil : ReviewSession(source: .largeFiles, rows: rows)
    }

    func removed(_ paths: Set<String>) {
        for file in files where paths.contains(file.id) { removedCache[file.id] = file }
        files.removeAll { paths.contains($0.id) }
        ticked.subtract(paths)
        selection.subtract(paths)
    }

    func restored(_ paths: Set<String>) {
        for path in paths {
            if let file = removedCache.removeValue(forKey: path) { files.append(file) }
        }
    }

    // MARK: Snapshot sample

    func loadSample() {
        stop()
        let samples: [(String, Int64, FileKind, Int)] = [
            ("Movies/Family Trip 2023 (4K export).mov", 18_400_000_000, .video, -400),
            ("Downloads/Xcode_16.2.xip", 7_210_000_000, .archive, -320),
            ("Documents/VMs/Windows 11 ARM.utm", 64_000_000_000, .other, -900),
            ("Downloads/ubuntu-24.04-desktop-arm64.iso", 2_900_000_000, .diskImage, -210),
            ("Downloads/Figma-125.3.dmg", 480_000_000, .diskImage, -60),
            ("Movies/Screen Recording 2025-10-03 at 14.22.11.mov", 1_340_000_000, .video, -29),
            ("Documents/Archive/Photos-backup-2021.zip", 12_800_000_000, .archive, -1_100),
            ("Music/GarageBand/Live Session.band", 820_000_000, .other, -15),
        ]
        files = samples.map { path, size, kind, days in
            LargeFile(url: home.appending(path: path), size: size, kind: kind,
                      lastOpened: Calendar.current.date(byAdding: .day, value: days, to: .now))
        }
        ticked = [home.appending(path: "Downloads/Xcode_16.2.xip").path, home.appending(path: "Downloads/ubuntu-24.04-desktop-arm64.iso").path]
        hasScanned = true
        scanning = false
    }
}
