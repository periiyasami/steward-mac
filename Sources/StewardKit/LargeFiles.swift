import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Broad file kinds for the Large & Old Files filter.
public enum FileKind: String, CaseIterable, Sendable, Codable {
    case video, archive, diskImage, other

    public var title: String {
        switch self {
        case .video: "Videos"
        case .archive: "Archives"
        case .diskImage: "Disk Images"
        case .other: "Other"
        }
    }

    /// The singular word for a row's Kind column.
    public var rowTitle: String {
        switch self {
        case .video: "Video"
        case .archive: "Archive"
        case .diskImage: "Disk Image"
        case .other: "Other"
        }
    }

    public static func of(_ type: UTType?) -> FileKind {
        guard let type else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if let image = UTType("public.disk-image"), type.conforms(to: image) { return .diskImage }
        if let dmg = UTType("com.apple.disk-image"), type.conforms(to: dmg) { return .diskImage }
        if type.conforms(to: .archive) { return .archive }
        return .other
    }
}

/// One big file (or package, like an .app or a .photoslibrary, counted as one).
public struct LargeFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let kind: FileKind
    /// From Spotlight's last-used date, falling back to the modification date.
    public let lastOpened: Date?
    public let isPackage: Bool

    public init(url: URL, size: Int64, kind: FileKind, lastOpened: Date?, isPackage: Bool = false) {
        self.url = url
        self.size = size
        self.kind = kind
        self.lastOpened = lastOpened
        self.isPackage = isPackage
    }

    public var name: String { url.lastPathComponent }
}

/// How long a file has gone unopened.
public enum FileAge: String, CaseIterable, Sendable {
    case any, sixMonths, oneYear, twoYears

    public var title: String {
        switch self {
        case .any: "Any Time"
        case .sixMonths: "Not Opened in 6 Months"
        case .oneYear: "Not Opened in 1 Year"
        case .twoYears: "Not Opened in 2 Years"
        }
    }

    public func cutoff(now: Date = .now) -> Date? {
        let cal = Calendar.current
        switch self {
        case .any: return nil
        case .sixMonths: return cal.date(byAdding: .month, value: -6, to: now)
        case .oneYear: return cal.date(byAdding: .year, value: -1, to: now)
        case .twoYears: return cal.date(byAdding: .year, value: -2, to: now)
        }
    }
}

public struct LargeFileFilter: Sendable, Hashable {
    public var minSize: Int64
    public var age: FileAge
    public var kind: FileKind?

    public init(minSize: Int64, age: FileAge = .any, kind: FileKind? = nil) {
        self.minSize = minSize
        self.age = age
        self.kind = kind
    }

    public func apply(_ files: [LargeFile], now: Date = .now) -> [LargeFile] {
        let cutoff = age.cutoff(now: now)
        return files.filter { file in
            guard file.size >= minSize else { return false }
            if let kind, file.kind != kind { return false }
            if let cutoff, let opened = file.lastOpened, opened > cutoff { return false }
            return true
        }
        .sorted { $0.size > $1.size }
    }

    public static let thresholds: [Int64] = [100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]
}

/// Walks a folder for files over a size. Skips hidden files and, when the
/// folder is the home folder, ~/Library (Smart Scan covers it).
public struct LargeFileFinder: Sendable {
    public let root: URL
    public let home: URL
    public let minSize: Int64
    public let skipped: SkipList

    public init(root: URL, home: URL, minSize: Int64 = LargeFileFilter.thresholds[0], skipped: SkipList = SkipList()) {
        self.root = root.standardizedFileURL
        self.home = home.standardizedFileURL
        self.minSize = minSize
        self.skipped = skipped
    }

    public enum Event: Sendable {
        case folder(URL)
        case found(LargeFile)
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                walk { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func run() async -> [LargeFile] {
        var files: [LargeFile] = []
        for await event in events() { if case .found(let f) = event { files.append(f) } }
        return files
    }

    func walk(emit: (Event) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentTypeKey, .contentModificationDateKey]
        let library = home.appending(path: "Library").path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
        else { return }
        var lastFolder = ""
        // The enumerator may resolve symlinks in the root (/tmp -> /private/tmp).
        // Report paths in the root's own form, so they match everything else.
        let resolvedRoot = Self.realPath(root.path)
        while let raw = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }
            var url = raw
            if raw.path.hasPrefix(resolvedRoot + "/"), resolvedRoot != root.path {
                url = root.appending(path: String(raw.path.dropFirst(resolvedRoot.count + 1)))
            }
            let path = url.standardizedFileURL.path
            if path == library || skipped.matches(url) {
                enumerator.skipDescendants()
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isPackage == true {
                enumerator.skipDescendants()
                let size = Sizer.allocatedSize(of: url)
                if size >= minSize {
                    emit(.found(LargeFile(url: url, size: size, kind: FileKind.of(v.contentType),
                                          lastOpened: Self.lastOpened(url, modified: v.contentModificationDate), isPackage: true)))
                }
                continue
            }
            if v.isDirectory == true {
                // Report the top two levels, so progress reads "Looking in Movies".
                let rel = PathGuard.relativePath(of: url, in: root) ?? ""
                if rel.split(separator: "/").count <= 2, rel != lastFolder {
                    lastFolder = rel
                    emit(.folder(url))
                }
                continue
            }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if size >= minSize {
                emit(.found(LargeFile(url: url, size: size, kind: FileKind.of(v.contentType),
                                      lastOpened: Self.lastOpened(url, modified: v.contentModificationDate))))
            }
        }
    }

    /// Spotlight's last-used date only, with no fallback (nil when never opened or not indexed).
    public static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The path with every symlink resolved. Foundation's resolvingSymlinksInPath
    /// turns /private/tmp back into /tmp, so it cannot be used to compare.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Spotlight's last-used date, or the modification date when Spotlight has none.
    public static func lastOpened(_ url: URL, modified: Date? = nil) -> Date? {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return used
        }
        return modified ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
