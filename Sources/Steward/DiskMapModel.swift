import AppKit
import Foundation
import Observation
import StewardKit

/// State for the Disk Map: the measured tree, where you are in it, and the
/// items collected for Review.
@Observable
final class DiskMapModel {
    let home: URL
    var root: URL
    var tree: DiskNode?
    /// Folder paths from the root down to the folder on screen.
    var path: [String] = []
    var measuring = false
    var hasMeasured = false
    /// Items added with "Add to Review", in the order they were added.
    var collected: [DiskNode] = []
    /// The block under the pointer, or selected in the list.
    var highlighted: String?

    private var task: Task<Void, Never>?

    init(home: URL) {
        self.home = home
        self.root = Prefs.diskMapStart.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? home
    }

    /// The folder on screen.
    var current: DiskNode? {
        guard var node = tree else { return nil }
        for p in path {
            guard let next = node.children.first(where: { $0.url.path == p && !$0.isOther }) else { break }
            node = next
        }
        return node
    }

    /// Root first, then each folder down to the one on screen.
    var trail: [DiskNode] {
        guard var node = tree else { return [] }
        var nodes = [node]
        for p in path {
            guard let next = node.children.first(where: { $0.url.path == p && !$0.isOther }) else { break }
            nodes.append(next)
            node = next
        }
        return nodes
    }

    func measure(_ url: URL? = nil) {
        if let url { root = url }
        task?.cancel()
        tree = nil
        path = []
        highlighted = nil
        measuring = true
        hasMeasured = true
        let mapper = DiskMapper(root: root)
        task = Task {
            for await event in mapper.events() {
                if Task.isCancelled { break }
                switch event {
                case .partial(let node), .finished(let node): tree = node
                }
            }
            measuring = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        measuring = false
    }

    func open(_ node: DiskNode) {
        guard node.isDirectory, !node.isOther else { return }
        if node.isTruncated {
            measure(node.url)
        } else {
            path.append(node.url.path)
            highlighted = nil
        }
    }

    var canGoUp: Bool { !path.isEmpty }

    func up() {
        guard canGoUp else { return }
        path.removeLast()
        highlighted = nil
    }

    /// Go to a folder in the trail (0 is the root).
    func go(to index: Int) {
        path = Array(path.prefix(index))
        highlighted = nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        panel.prompt = "Choose"
        panel.message = "Choose a folder to see what takes up space in it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        measure(url)
    }

    // MARK: Review

    func canCollect(_ node: DiskNode) -> Bool {
        !node.isOther && PathGuard.isAllowed(node.url, home: home)
    }

    func isCollected(_ node: DiskNode) -> Bool { collected.contains { $0.url == node.url } }

    func toggleCollected(_ node: DiskNode) {
        if isCollected(node) {
            collected.removeAll { $0.url == node.url }
        } else if canCollect(node) {
            // A folder and something inside it: keep only the outer one.
            collected.removeAll { $0.url.path.hasPrefix(node.url.path + "/") }
            if !collected.contains(where: { node.url.path.hasPrefix($0.url.path + "/") }) {
                collected.append(node)
            }
        }
    }

    var collectedBytes: Int64 { collected.reduce(0) { $0 + $1.size } }

    func reviewSession() -> ReviewSession? {
        guard !collected.isEmpty else { return nil }
        let rows = collected.map {
            Candidate(url: $0.url, size: $0.size, reason: $0.isDirectory ? "Folder chosen in Disk Map" : "File chosen in Disk Map",
                      group: "Disk Map")
        }
        return ReviewSession(source: .diskMap, rows: rows)
    }

    func removed(_ paths: Set<String>) {
        tree = tree?.removing(paths)
        collected.removeAll { paths.contains($0.url.path) }
    }

    func restored() {
        if hasMeasured, !Store.isOverridden { measure() }
    }

    // MARK: Snapshot sample

    func loadSample() {
        stop()
        func f(_ p: String, _ s: Int64, _ k: FileKind = .other) -> DiskNode {
            DiskNode(url: home.appending(path: p), size: s, isDirectory: false, kind: k)
        }
        func d(_ p: String, _ kids: [DiskNode]) -> DiskNode {
            DiskNode(url: home.appending(path: p), size: kids.reduce(0) { $0 + $1.size }, isDirectory: true,
                     children: kids.sorted { $0.size > $1.size })
        }
        let movies = d("Movies", [f("Movies/Family Trip 2023 (4K export).mov", 18_400_000_000, .video),
                                  f("Movies/Screen Recording 2025-10-03.mov", 1_340_000_000, .video),
                                  d("Movies/Final Cut Library.fcpbundle", [f("Movies/Final Cut Library.fcpbundle/Media", 9_600_000_000, .video)])])
        let documents = d("Documents", [f("Documents/VMs/Windows 11 ARM.utm", 64_000_000_000),
                                        f("Documents/Archive/Photos-backup-2021.zip", 12_800_000_000, .archive),
                                        d("Documents/Projects", [f("Documents/Projects/site/node_modules", 2_100_000_000),
                                                                 f("Documents/Projects/app/.build", 3_400_000_000)])])
        let downloads = d("Downloads", [f("Downloads/Xcode_16.2.xip", 7_210_000_000, .archive),
                                        f("Downloads/ubuntu-24.04-desktop-arm64.iso", 2_900_000_000, .diskImage),
                                        f("Downloads/Figma-125.3.dmg", 480_000_000, .diskImage)])
        let library = d("Library", [d("Library/Developer", [f("Library/Developer/Xcode", 38_000_000_000),
                                                            f("Library/Developer/CoreSimulator", 21_000_000_000)]),
                                    f("Library/Caches", 6_300_000_000), f("Library/Application Support", 14_200_000_000),
                                    f("Library/Containers", 9_800_000_000)])
        let pictures = d("Pictures", [f("Pictures/Photos Library.photoslibrary", 48_500_000_000)])
        let music = d("Music", [f("Music/Music", 11_200_000_000)])
        let kids = [movies, documents, downloads, library, pictures, music, f("Desktop", 1_900_000_000)]
        tree = DiskNode(url: home, size: kids.reduce(0) { $0 + $1.size }, isDirectory: true, children: kids.sorted { $0.size > $1.size })
        root = home
        path = []
        collected = [downloads.children[0]]
        hasMeasured = true
        measuring = false
    }
}
