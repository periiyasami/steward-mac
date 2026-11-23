import Foundation

/// One file or folder Steward found.
public struct ScanItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public let url: URL
    public let category: ScanCategory
    /// Bytes on disk.
    public let size: Int64
    public let lastOpened: Date?

    public init(url: URL, category: ScanCategory, size: Int64, lastOpened: Date?) {
        self.url = url
        self.category = category
        self.size = size
        self.lastOpened = lastOpened
    }

    public var name: String { url.lastPathComponent }
}

public enum ScanEvent: Sendable {
    case started(ScanCategory)
    case found(ScanItem)
    /// A folder Steward could not read, usually for lack of Full Disk Access.
    case notScanned(URL)
}

/// Set once when a scan is stopped. Worker threads read it, because
/// Task.isCancelled is false on threads that don't belong to the task.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } || Task.isCancelled }
}

/// Finds Smart Scan items under a home folder. Runs off the main actor.
public struct Scanner: Sendable {
    public let home: URL
    public let skipped: SkipList
    public let categories: [ScanCategory]
    /// The time age rules count from. Tests set it.
    public let now: Date

    public init(home: URL, skipped: SkipList = SkipList(), categories: [ScanCategory] = ScanCategory.allCases, now: Date = .now) {
        self.home = home.standardizedFileURL
        self.skipped = skipped
        self.categories = categories
        self.now = now
    }

    /// Streams events as they happen. Cancelling the consuming task stops the scan.
    public func events() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let flag = CancelFlag()
            let task = Task.detached(priority: .userInitiated) {
                for category in categories {
                    if flag.isCancelled { break }
                    continuation.yield(.started(category))
                    scan(category, flag: flag) { continuation.yield($0) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                flag.cancel()
                task.cancel()
            }
        }
    }

    /// Runs the whole scan and returns the items, for tests and the self-test.
    public func run() async -> (items: [ScanItem], notScanned: [URL]) {
        var items: [ScanItem] = []
        var notScanned: [URL] = []
        for await event in events() {
            switch event {
            case .found(let item): items.append(item)
            case .notScanned(let url): notScanned.append(url)
            case .started: break
            }
        }
        return (items, notScanned)
    }

    func cutoff(for category: ScanCategory) -> Date? {
        category.minimumAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    func scan(_ category: ScanCategory, flag: CancelFlag = CancelFlag(), emit: (ScanEvent) -> Void) {
        if category == .projectBuilds {
            measure(projectArtifacts(flag: flag), category: category, flag: flag, emit: emit)
            return
        }
        let fm = FileManager.default
        for folder in category.folders {
            let dir = home.appending(path: folder, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Never scan through a symlinked category folder.
            if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let children: [URL]
            do {
                // Rebuild each child from `dir`, so paths keep the home folder's form
                // (Foundation returns /private/tmp for /tmp, for example).
                children = try fm.contentsOfDirectory(atPath: dir.path).map { dir.appending(path: $0) }
            } catch {
                emit(.notScanned(dir))
                continue
            }
            let accepted = children.sorted { $0.path < $1.path }.filter {
                category.accepts($0.lastPathComponent, in: folder) && PathGuard.isAllowed($0, home: home) && !skipped.matches($0)
            }
            measure(accepted, category: category, flag: flag, emit: emit)
            if flag.isCancelled { return }
        }
    }

    /// Sizes items on several threads at once, then emits them in order.
    func measure(_ urls: [URL], category: ScanCategory, flag: CancelFlag, emit: (ScanEvent) -> Void) {
        guard !urls.isEmpty else { return }
        struct Measured: Sendable {
            var size: Int64 = 0
            var unreadable: URL?
            var tooNew = false
        }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int: Measured] = [:]
            func set(_ i: Int, _ m: Measured) { lock.withLock { values[i] = m } }
        }
        let results = Results()
        let ageCutoff = self.cutoff(for: category)
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            if flag.isCancelled { return }
            var m = Measured()
            let url = urls[i]
            if let cutoff = ageCutoff {
                // Project Dependencies count the project's own files; logs count their own.
                let target = category == .projectBuilds ? url.deletingLastPathComponent() : url
                let skip = category == .projectBuilds ? Set(ScanCategory.projectArtifacts.keys) : []
                if Sizer.isTouched(target, after: cutoff, skipping: skip, isCancelled: { flag.isCancelled }) {
                    m.tooNew = true
                    results.set(i, m)
                    return
                }
            }
            m.size = Sizer.allocatedSize(of: url, unreadable: { m.unreadable = $0 }, isCancelled: { flag.isCancelled })
            results.set(i, m)
        }
        for (i, url) in urls.enumerated() {
            if flag.isCancelled { return }
            guard let m = results.values[i], !m.tooNew else { continue }
            if let bad = m.unreadable { emit(.notScanned(bad)) }
            guard m.size > 0 else { continue }
            emit(.found(ScanItem(url: url, category: category, size: m.size, lastOpened: Sizer.lastOpened(url))))
        }
    }

    /// node_modules, .build, Pods, and target folders next to the file that
    /// marks their project, in the usual project folders. Never inside another
    /// artifact, a hidden folder, or a package.
    func projectArtifacts(flag: CancelFlag) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var found: [URL] = []
        var seenRoots = Set<String>()
        for rootName in ScanCategory.projectRoots {
            let root = home.appending(path: rootName, directoryHint: .isDirectory)
            guard let v = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            // "Code" and "code" are one folder on most Macs.
            let identity = v.fileResourceIdentifier.map { "\($0)" } ?? root.path.lowercased()
            guard seenRoots.insert(identity).inserted else { continue }
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            else { continue }
            let resolvedRoot = LargeFileFinder.realPath(root.path)
            while let raw = e.nextObject() as? URL {
                if flag.isCancelled { return found }
                guard let rv = try? raw.resourceValues(forKeys: Set(keys)), rv.isDirectory == true, rv.isSymbolicLink != true else { continue }
                if rv.isPackage == true || e.level > 6 { e.skipDescendants(); continue }
                let name = raw.lastPathComponent
                if let marker = ScanCategory.projectArtifacts[name] {
                    e.skipDescendants()
                    guard fm.fileExists(atPath: raw.deletingLastPathComponent().appending(path: marker).path) else { continue }
                    // Report the path in the home folder's own form (/tmp, not /private/tmp).
                    var url = raw
                    if raw.path.hasPrefix(resolvedRoot + "/"), resolvedRoot != root.path {
                        url = root.appending(path: String(raw.path.dropFirst(resolvedRoot.count + 1)))
                    }
                    if PathGuard.isAllowed(url, home: home), !skipped.matches(url) { found.append(url) }
                    continue
                }
                if name.hasPrefix(".") || skipped.matches(raw) { e.skipDescendants() }
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

public enum Sizer {
    /// Bytes on disk for a file or a folder tree. Symlinks count as themselves,
    /// never their targets. Unreadable subfolders are reported and skipped.
    public static func allocatedSize(of url: URL, unreadable: (URL) -> Void = { _ in },
                                     isCancelled: () -> Bool = { Task.isCancelled }) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        var firstFailure: URL?
        // The enumerator does not descend into symlinked folders.
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { failed, _ in
                if firstFailure == nil { firstFailure = failed }
                return true
            })
        defer { if let firstFailure { unreadable(firstFailure) } }
        while let next = enumerator?.nextObject() as? URL {
            if isCancelled() { break }
            let v = try? next.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Whether any file in `url` (or `url` itself, for a file) changed after
    /// `cutoff`. Folders named in `skipping`, and hidden folders when skipping
    /// anything, are not looked into. Stops at the first new file.
    public static func isTouched(_ url: URL, after cutoff: Date, skipping: Set<String> = [],
                                 isCancelled: () -> Bool = { Task.isCancelled }) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isDirectory != true || values.isSymbolicLink == true {
            return (values.contentModificationDate ?? .distantPast) > cutoff
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                     errorHandler: { _, _ in true }) else { return false }
        while let next = e.nextObject() as? URL {
            if isCancelled() { return false }
            guard let v = try? next.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true {
                let name = next.lastPathComponent
                if skipping.contains(name) || (!skipping.isEmpty && name.hasPrefix(".")) { e.skipDescendants() }
                continue
            }
            if (v.contentModificationDate ?? .distantPast) > cutoff { return true }
        }
        return false
    }

    public static func lastOpened(_ url: URL) -> Date? {
        let v = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return v?.contentAccessDate ?? v?.contentModificationDate
    }
}
