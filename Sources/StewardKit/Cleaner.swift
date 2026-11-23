import Foundation

/// Where Move to Trash sends things.
public protocol TrashMover: Sendable {
    /// Moves the item to the Trash and returns where it ended up.
    func moveToTrash(_ url: URL) throws -> URL
}

/// The real Trash, through Foundation's Move to Trash. Never deletes.
public struct SystemTrash: TrashMover {
    public init() {}
    public func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }
}

/// A folder that stands in for the Trash in tests and the self-test.
public struct FolderTrash: TrashMover {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }
    public func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var dest = folder.appending(path: url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n)")
                .appendingPathExtension(url.pathExtension)
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

public struct CleanRequest: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let isAppBundle: Bool
    public init(url: URL, size: Int64, isAppBundle: Bool = false) {
        self.url = url
        self.size = size
        self.isAppBundle = isAppBundle
    }
}

public struct MovedItem: Sendable, Hashable, Codable {
    public let original: URL
    public let inTrash: URL
    public let size: Int64
    public init(original: URL, inTrash: URL, size: Int64) {
        self.original = original
        self.inTrash = inTrash
        self.size = size
    }
}

public struct FailedItem: Sendable, Hashable {
    public let url: URL
    public let message: String
    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public struct CleanOutcome: Sendable {
    public var moved: [MovedItem] = []
    public var failed: [FailedItem] = []
    public var bytes: Int64 { moved.reduce(0) { $0 + $1.size } }
}

public struct UndoOutcome: Sendable {
    public var restored: [MovedItem] = []
    /// Items left in the Trash: gone from it, or their original path is taken.
    public var skipped: [MovedItem] = []
}

/// Moves items to the Trash and puts them back. Every path is checked
/// against PathGuard first, so nothing outside the home folder can move.
public struct Cleaner: Sendable {
    public let home: URL
    public let trash: TrashMover
    /// Folders app bundles may be moved from. nil means /Applications and ~/Applications.
    public let applications: [URL]?

    public init(home: URL, trash: TrashMover = SystemTrash(), applications: [URL]? = nil) {
        self.home = home
        self.trash = trash
        self.applications = applications
    }

    public func moveToTrash(_ items: [(url: URL, size: Int64)]) -> CleanOutcome {
        moveToTrash(items.map { CleanRequest(url: $0.url, size: $0.size) })
    }

    public func moveToTrash(_ items: [CleanRequest]) -> CleanOutcome {
        var outcome = CleanOutcome()
        for item in items {
            let allowed = PathGuard.isAllowed(item.url, home: home)
                || (item.isAppBundle && AppGuard.isRemovableApp(item.url, home: home, applications: applications))
            guard allowed else {
                outcome.failed.append(FailedItem(url: item.url, message: "Outside your home folder"))
                continue
            }
            do {
                let dest = try trash.moveToTrash(item.url)
                outcome.moved.append(MovedItem(original: item.url, inTrash: dest, size: item.size))
            } catch {
                outcome.failed.append(FailedItem(url: item.url, message: Self.describe(error)))
            }
        }
        return outcome
    }

    public func undo(_ moved: [MovedItem]) -> UndoOutcome {
        let fm = FileManager.default
        var outcome = UndoOutcome()
        for item in moved {
            guard fm.fileExists(atPath: item.inTrash.path),
                  !fm.fileExists(atPath: item.original.path),
                  PathGuard.isAllowed(item.original, home: home)
                    || AppGuard.isRemovableApp(item.original, home: home, applications: applications) else {
                outcome.skipped.append(item)
                continue
            }
            do {
                try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: item.inTrash, to: item.original)
                outcome.restored.append(item)
            } catch {
                outcome.skipped.append(item)
            }
        }
        return outcome
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "No permission"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "Already gone"
            default: break
            }
        }
        return ns.localizedDescription
    }
}

/// Full Disk Access check: macOS gives no API, so try to read a file that
/// only Full Disk Access can open.
public enum AccessCheck {
    public static func hasFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
            "Library/Mail",
        ]
        for probe in probes {
            let url = home.appending(path: probe)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                return true
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return true }
            return false
        }
        return false
    }
}
