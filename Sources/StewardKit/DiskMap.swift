import CoreGraphics
import Darwin
import Foundation
import UniformTypeIdentifiers

/// One block in the Disk Map: a file, a folder with its biggest children,
/// or the "smaller items" that are folded together.
public struct DiskNode: Identifiable, Hashable, Sendable {
    public var id: String { url.path + (isOther ? "#other" : "") }
    public let url: URL
    public var size: Int64
    public let isDirectory: Bool
    public let kind: FileKind
    public var children: [DiskNode]
    /// The folded "smaller items" block.
    public var isOther = false
    /// Children were not kept (too deep); drilling in measures this folder again.
    public var isTruncated = false

    public init(url: URL, size: Int64, isDirectory: Bool, kind: FileKind = .other, children: [DiskNode] = [],
                isOther: Bool = false, isTruncated: Bool = false) {
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.kind = kind
        self.children = children
        self.isOther = isOther
        self.isTruncated = isTruncated
    }

    public var name: String { isOther ? "Smaller Items" : url.lastPathComponent }

    /// This tree without the given paths, with sizes reduced up the chain.
    public func removing(_ paths: Set<String>) -> DiskNode? {
        if paths.contains(url.path), !isOther { return nil }
        guard isDirectory, !children.isEmpty else { return self }
        var copy = self
        var kept: [DiskNode] = []
        for child in children {
            if let c = child.removing(paths) {
                kept.append(c)
                copy.size -= child.size - c.size
            } else {
                copy.size -= child.size
            }
        }
        copy.children = kept
        return copy
    }
}

/// Measures a folder for the Disk Map. Sizes are bytes on disk; a file with
/// several hard links counts once; symlinks count as themselves.
public struct DiskMapper: Sendable {
    public let root: URL
    /// Levels of children kept below the root. Deeper folders keep only their size.
    public let keepDepth: Int
    /// Children kept per folder; the rest fold into "Smaller Items".
    public let keepChildren: Int

    public init(root: URL, keepDepth: Int = 6, keepChildren: Int = 60) {
        self.root = root.standardizedFileURL
        self.keepDepth = keepDepth
        self.keepChildren = keepChildren
    }

    public enum Event: Sendable {
        /// The root so far: every top-level child measured until now.
        case partial(DiskNode)
        case finished(DiskNode)
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var seen = Set<FileID>()
                let node = measureRoot(seen: &seen) { continuation.yield(.partial($0)) }
                if !Task.isCancelled { continuation.yield(.finished(node)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func run() async -> DiskNode? {
        var last: DiskNode?
        for await event in events() { if case .finished(let n) = event { last = n } }
        return last
    }

    struct FileID: Hashable { let dev: Int32; let ino: UInt64 }

    func measureRoot(seen: inout Set<FileID>, progress: (DiskNode) -> Void) -> DiskNode {
        var root = DiskNode(url: root, size: 0, isDirectory: true)
        var children: [DiskNode] = []
        for url in contents(of: self.root) {
            if Task.isCancelled { break }
            if let child = measure(url, depth: 1, seen: &seen) {
                children.append(child)
                root.size += child.size
                root.children = fold(children, in: self.root)
                progress(root)
            }
        }
        root.children = fold(children, in: self.root)
        return root
    }

    func measure(_ url: URL, depth: Int, seen: inout Set<FileID>) -> DiskNode? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let isPackage = isDir && ((try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true)
        if !isDir || isPackage {
            let size = isPackage ? packageSize(url, seen: &seen) : fileSize(st, seen: &seen)
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            return DiskNode(url: url, size: size, isDirectory: false, kind: FileKind.of(type))
        }
        var size = Int64(st.st_blocks) * 512
        var children: [DiskNode] = []
        for child in contents(of: url) {
            if Task.isCancelled { break }
            guard let node = measure(child, depth: depth + 1, seen: &seen) else { continue }
            size += node.size
            if depth < keepDepth { children.append(node) }
        }
        return DiskNode(url: url, size: size, isDirectory: true, children: fold(children, in: url),
                        isTruncated: depth >= keepDepth)
    }

    private func fileSize(_ st: stat, seen: inout Set<FileID>) -> Int64 {
        if st.st_nlink > 1 {
            let id = FileID(dev: st.st_dev, ino: st.st_ino)
            if seen.contains(id) { return 0 }
            seen.insert(id)
        }
        return Int64(st.st_blocks) * 512
    }

    private func packageSize(_ url: URL, seen: inout Set<FileID>) -> Int64 {
        var total: Int64 = 0
        var st = stat()
        if lstat(url.path, &st) == 0 { total += Int64(st.st_blocks) * 512 }
        guard let e = FileManager.default.enumerator(atPath: url.path) else { return total }
        while let rel = e.nextObject() as? String {
            if Task.isCancelled { break }
            if lstat(url.path + "/" + rel, &st) == 0 { total += fileSize(st, seen: &seen) }
        }
        return total
    }

    private func contents(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).map { url.appending(path: $0) }
    }

    /// Biggest first; past `keepChildren`, the rest become one "Smaller Items" block.
    func fold(_ nodes: [DiskNode], in parent: URL) -> [DiskNode] {
        let sorted = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard sorted.count > keepChildren else { return sorted }
        let rest = sorted[keepChildren...]
        let other = DiskNode(url: parent, size: rest.reduce(0) { $0 + $1.size }, isDirectory: false, isOther: true)
        return Array(sorted[..<keepChildren]) + [other]
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk): blocks keep their
/// share of the area and stay close to square.
public enum Treemap {
    public struct Block: Sendable, Hashable {
        public let index: Int
        public let rect: CGRect
    }

    public static func layout(_ sizes: [Double], in rect: CGRect) -> [Block] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        let items = sizes.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, area: $0.element * scale) }
            .sorted { $0.area > $1.area }
        var blocks: [Block] = []
        var remaining = rect
        var row: [(index: Int, area: Double)] = []
        var i = 0
        while i < items.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [items[i]]
            if row.isEmpty || worst(candidate, side: side) <= worst(row, side: side) {
                row = candidate
                i += 1
            } else {
                remaining = place(row, in: remaining, into: &blocks)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, in: remaining, into: &blocks) }
        return blocks
    }

    private static func worst(_ row: [(index: Int, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0 else { return .infinity }
        let maxA = row.map(\.area).max() ?? 0
        let minA = row.map(\.area).min() ?? 0
        return max(side * side * maxA / (sum * sum), (sum * sum) / (side * side * minA))
    }

    private static func place(_ row: [(index: Int, area: Double)], in rect: CGRect, into blocks: inout [Block]) -> CGRect {
        let sum = row.reduce(0) { $0 + $1.area }
        if rect.width >= rect.height {
            // A column on the left.
            let w = CGFloat(sum) / rect.height
            var y = rect.minY
            for item in row {
                let h = CGFloat(item.area) / w
                blocks.append(Block(index: item.index, rect: CGRect(x: rect.minX, y: y, width: w, height: h)))
                y += h
            }
            return CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
        } else {
            // A row on top.
            let h = CGFloat(sum) / rect.width
            var x = rect.minX
            for item in row {
                let w = CGFloat(item.area) / h
                blocks.append(Block(index: item.index, rect: CGRect(x: x, y: rect.minY, width: w, height: h)))
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
        }
    }
}
