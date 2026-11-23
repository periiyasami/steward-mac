import AppKit
import Foundation
import Observation
import StewardKit

/// State for Duplicates. Nothing is ticked until the person asks; Review
/// never takes every copy of a file.
@Observable
final class DuplicatesModel {
    let home: URL
    var root: URL
    var groups: [DuplicateGroup] = []
    var scanning = false
    var hasScanned = false
    var currentFolder: URL?
    /// Files compared so far, of how many, while comparing contents.
    var comparing: (done: Int, total: Int)?
    var minSize: Int64 = Prefs.duplicateMinSize

    var ticked: Set<String> = []
    var selection: Set<String> = []
    var preview: URL?
    /// Said when Review kept a copy back.
    var message: String?

    private var task: Task<Void, Never>?
    /// Files that moved, by group, so Undo can show them again.
    private var removedCache: [String: (group: DuplicateGroup, file: DuplicateFile)] = [:]

    init(home: URL) {
        self.home = home
        self.root = home
    }

    var allFiles: [DuplicateFile] { groups.flatMap(\.files) }
    var tickedFiles: [DuplicateFile] { allFiles.filter { ticked.contains($0.id) } }
    var tickedBytes: Int64 { groups.reduce(0) { sum, g in sum + g.size * Int64(g.files.filter { ticked.contains($0.id) }.count) } }
    var extraBytes: Int64 { groups.reduce(0) { $0 + $1.extraBytes } }
    var selectedURLs: [URL] { allFiles.filter { selection.contains($0.id) }.map(\.url) }

    var status: String? {
        guard scanning else { return nil }
        if let comparing { return "Comparing \(comparing.done) of \(comparing.total) files…" }
        return currentFolder.map { "Looking in \(Self.short($0, home: home))…" } ?? "Looking for files…"
    }

    static func short(_ url: URL, home: URL) -> String {
        guard let rel = PathGuard.relativePath(of: url, in: home) else { return url.path }
        return rel.isEmpty ? "~" : "~/" + rel
    }

    func scan(skipped: SkipList) {
        task?.cancel()
        groups = []
        ticked = []
        selection = []
        message = nil
        comparing = nil
        removedCache = [:]
        scanning = true
        hasScanned = true
        let finder = DuplicateFinder(root: root, home: home, minSize: minSize, skipped: skipped)
        task = Task {
            for await event in finder.events() {
                if Task.isCancelled { break }
                switch event {
                case .folder(let url): currentFolder = url
                case .comparing(let done, let total): comparing = (done, total)
                case .found(let group): groups.append(group)
                }
            }
            groups.sort { $0.extraBytes > $1.extraBytes }
            scanning = false
            currentFolder = nil
            comparing = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        scanning = false
        currentFolder = nil
        comparing = nil
    }

    func chooseFolder(skipped: SkipList) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Choose"
        panel.message = "Choose a folder to look through for duplicate files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        scan(skipped: skipped)
    }

    func toggle(_ file: DuplicateFile) {
        if ticked.contains(file.id) { ticked.remove(file.id) } else { ticked.insert(file.id) }
    }

    /// Ticks every copy except the one Steward suggests keeping.
    func tickExtraCopies() {
        for group in groups {
            ticked.remove(group.keep.id)
            ticked.formUnion(group.files.dropFirst().map(\.id))
        }
    }

    /// Review for the ticked copies. When every copy of a file is ticked, the
    /// suggested one stays behind, so one copy always remains.
    func reviewSession() -> ReviewSession? {
        var rows: [Candidate] = []
        var keptBack = 0
        for group in groups {
            var chosen = group.files.filter { ticked.contains($0.id) }
            if chosen.count == group.files.count {
                chosen.removeAll { $0.id == group.keep.id }
                ticked.remove(group.keep.id)
                keptBack += 1
            }
            let keep = group.files.first { !ticked.contains($0.id) } ?? group.keep
            rows += chosen.map {
                Candidate(url: $0.url, size: group.size,
                          reason: "Same as \(keep.name) in \(Self.short(keep.url.deletingLastPathComponent(), home: home))",
                          group: "Duplicate")
            }
        }
        message = keptBack == 0 ? nil
            : "Every copy of \(Count.items(keptBack)) was ticked. Steward keeps one copy of each, so it unticked the suggested one."
        return rows.isEmpty ? nil : ReviewSession(source: .duplicates, rows: rows)
    }

    func removed(_ paths: Set<String>) {
        for group in groups {
            for file in group.files where paths.contains(file.id) { removedCache[file.id] = (group, file) }
        }
        groups = groups.compactMap { $0.removing(paths) }
        ticked.subtract(paths)
        selection.subtract(paths)
    }

    func restored(_ paths: Set<String>) {
        var byGroup: [String: (DuplicateGroup, [DuplicateFile])] = [:]
        for path in paths {
            guard let entry = removedCache.removeValue(forKey: path) else { continue }
            byGroup[entry.group.id, default: (entry.group, [])].1.append(entry.file)
        }
        for (id, (original, files)) in byGroup {
            if let i = groups.firstIndex(where: { $0.id == id }) {
                let current = groups[i]
                let merged = original.files.filter { f in current.files.contains(f) || files.contains(f) }
                groups[i] = DuplicateGroup(id: id, size: original.size, files: merged)
            } else {
                let left = original.files.filter { f in files.contains(f) || removedCache[f.id] == nil && FileManager.default.fileExists(atPath: f.url.path) }
                if left.count >= 2 { groups.append(DuplicateGroup(id: id, size: original.size, files: left)) }
            }
        }
        groups.sort { $0.extraBytes > $1.extraBytes }
    }

    // MARK: Snapshot sample

    func loadSample() {
        stop()
        func g(_ id: String, _ size: Int64, _ paths: [String], days: [Int]) -> DuplicateGroup {
            DuplicateGroup(id: id, size: size, files: zip(paths, days).map { p, d in
                DuplicateFile(url: home.appending(path: p), modified: Calendar.current.date(byAdding: .day, value: d, to: .now))
            })
        }
        groups = [
            g("a1", 2_900_000_000, ["Documents/ISOs/ubuntu-24.04-desktop-arm64.iso", "Downloads/ubuntu-24.04-desktop-arm64.iso"], days: [-300, -12]),
            g("b2", 840_000_000, ["Movies/Wedding/ceremony.mov", "Desktop/ceremony copy.mov", "Downloads/ceremony.mov"], days: [-900, -40, -38]),
            g("c3", 64_000_000, ["Documents/Taxes/2024 return.pdf", "Downloads/2024 return (1).pdf"], days: [-200, -199]),
            g("d4", 12_400_000, ["Pictures/Exports/IMG_2041.heic", "Pictures/Exports/IMG_2041 copy.heic"], days: [-60, -60]),
        ]
        ticked = [home.appending(path: "Downloads/ubuntu-24.04-desktop-arm64.iso").path]
        hasScanned = true
        scanning = false
    }
}
