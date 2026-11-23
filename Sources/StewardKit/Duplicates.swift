import CryptoKit
import Foundation

/// One copy of a duplicated file.
public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let modified: Date?

    public init(url: URL, modified: Date?) {
        self.url = url
        self.modified = modified
    }

    public var name: String { url.lastPathComponent }
}

/// Files with exactly the same contents.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    /// The SHA-256 of the contents.
    public let id: String
    /// The size of each copy, in bytes.
    public let size: Int64
    /// The copy Steward suggests keeping comes first.
    public let files: [DuplicateFile]

    public init(id: String, size: Int64, files: [DuplicateFile]) {
        self.id = id
        self.size = size
        self.files = files
    }

    public var keep: DuplicateFile { files[0] }
    /// Space the extra copies take.
    public var extraBytes: Int64 { size * Int64(max(files.count - 1, 0)) }

    /// The same group with some files left out, or nil when fewer than two remain.
    public func removing(_ paths: Set<String>) -> DuplicateGroup? {
        let left = files.filter { !paths.contains($0.id) }
        return left.count >= 2 ? DuplicateGroup(id: id, size: size, files: left) : nil
    }
}

/// Finds files with the same contents: same size, then the same first and
/// last 16 KB, then the same SHA-256 of the whole file. Skips hidden files,
/// symlinks, the insides of packages, ~/Library when looking through the home
/// folder, and extra hard links to one file (they take no extra space).
public struct DuplicateFinder: Sendable {
    public static let sizeChoices: [Int64] = [100_000, 1_000_000, 10_000_000, 100_000_000]

    public let root: URL
    public let home: URL
    public let minSize: Int64
    public let skipped: SkipList

    public init(root: URL, home: URL, minSize: Int64 = sizeChoices[1], skipped: SkipList = SkipList()) {
        self.root = root.standardizedFileURL
        self.home = home.standardizedFileURL
        self.minSize = max(minSize, 1)
        self.skipped = skipped
    }

    public enum Event: Sendable {
        /// Looking through a folder (the top two levels are reported).
        case folder(URL)
        /// Comparing contents: files compared so far, of how many.
        case comparing(done: Int, total: Int)
        case found(DuplicateGroup)
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let flag = CancelFlag()
            let task = Task.detached(priority: .userInitiated) {
                find(flag: flag) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                flag.cancel()
                task.cancel()
            }
        }
    }

    public func run() async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        for await event in events() { if case .found(let g) = event { groups.append(g) } }
        return groups
    }

    struct Candidate {
        let url: URL
        let size: Int64
        let modified: Date?
    }

    func find(flag: CancelFlag, emit: (Event) -> Void) {
        let bySize = Dictionary(grouping: collect(flag: flag, emit: emit), by: \.size).filter { $0.value.count > 1 }
        let total = bySize.values.reduce(0) { $0 + $1.count }
        var done = 0
        // Biggest first, so the groups that free the most show first.
        for size in bySize.keys.sorted(by: >) {
            if flag.isCancelled { return }
            let same = bySize[size] ?? []
            let byPartial = Dictionary(grouping: same) { Self.partialHash($0.url) ?? "unreadable:\($0.url.path)" }
            for (_, partial) in byPartial where partial.count > 1 {
                let byFull = Dictionary(grouping: partial) { Self.fullHash($0.url, flag: flag) ?? "unreadable:\($0.url.path)" }
                for (hash, files) in byFull where files.count > 1 && !hash.hasPrefix("unreadable:") {
                    if flag.isCancelled { return }
                    emit(.found(DuplicateGroup(id: hash, size: size, files: ordered(files))))
                }
            }
            done += same.count
            emit(.comparing(done: done, total: total))
        }
    }

    /// Every regular file at or over the minimum size.
    func collect(flag: CancelFlag, emit: (Event) -> Void) -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
                                      .contentModificationDateKey, .fileResourceIdentifierKey]
        let library = home.appending(path: "Library").path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
        else { return [] }
        let resolvedRoot = LargeFileFinder.realPath(root.path)
        var found: [Candidate] = []
        var seen = Set<String>()
        var lastFolder = ""
        while let raw = enumerator.nextObject() as? URL {
            if flag.isCancelled { return found }
            var url = raw
            if raw.path.hasPrefix(resolvedRoot + "/"), resolvedRoot != root.path {
                url = root.appending(path: String(raw.path.dropFirst(resolvedRoot.count + 1)))
            }
            if url.standardizedFileURL.path == library || skipped.matches(url) {
                enumerator.skipDescendants()
                continue
            }
            guard let v = try? raw.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            if v.isDirectory == true {
                let rel = PathGuard.relativePath(of: url, in: root) ?? ""
                if rel.split(separator: "/").count <= 2, rel != lastFolder {
                    lastFolder = rel
                    emit(.folder(url))
                }
                continue
            }
            guard v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minSize else { continue }
            // Hard links to one file are one file.
            if let id = v.fileResourceIdentifier, !seen.insert("\(id)").inserted { continue }
            found.append(Candidate(url: url, size: Int64(size), modified: v.contentModificationDate))
        }
        return found
    }

    /// The copy to keep first: one outside Downloads and Desktop, then the
    /// oldest, then the shortest path.
    func ordered(_ files: [Candidate]) -> [DuplicateFile] {
        let scratch = ["Downloads", "Desktop"].map { home.appending(path: $0).path + "/" }
        func isScratch(_ c: Candidate) -> Bool { scratch.contains { c.url.path.hasPrefix($0) } }
        return files.sorted { a, b in
            let sa = isScratch(a), sb = isScratch(b)
            if sa != sb { return !sa }
            let da = a.modified ?? .distantFuture, db = b.modified ?? .distantFuture
            if da != db { return da < db }
            if a.url.path.count != b.url.path.count { return a.url.path.count < b.url.path.count }
            return a.url.path < b.url.path
        }.map { DuplicateFile(url: $0.url, modified: $0.modified) }
    }

    static let partialLength = 16 * 1024

    /// SHA-256 of the first and last 16 KB.
    static func partialHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // read returns nil, not empty data, at the end of a file.
        guard let head = try? handle.read(upToCount: partialLength) else { return nil }
        hasher.update(data: head)
        if let end = try? handle.seekToEnd(), end > UInt64(partialLength * 2) {
            try? handle.seek(toOffset: end - UInt64(partialLength))
            if let tail = try? handle.read(upToCount: partialLength) { hasher.update(data: tail) }
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of the whole file, read 1 MB at a time.
    static func fullHash(_ url: URL, flag: CancelFlag = CancelFlag()) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if flag.isCancelled { return nil }
            do {
                // nil or empty data at the end of the file.
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            } catch {
                return nil
            }
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
