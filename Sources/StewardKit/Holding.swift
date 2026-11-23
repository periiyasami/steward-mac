import Foundation

/// One item waiting in the holding area.
public struct HeldItem: Identifiable, Hashable, Sendable {
    public var id: String { location.path }
    /// The batch folder Steward made for it: <holding>/<UUID>.
    public let batch: URL
    /// Where the item is now: <batch>/<name>.
    public let location: URL
    /// Where it came from. nil when the note beside it is unreadable.
    public let original: URL?
    public let heldAt: Date
    public let size: Int64

    public init(batch: URL, location: URL, original: URL?, heldAt: Date, size: Int64) {
        self.batch = batch
        self.location = location
        self.original = original
        self.heldAt = heldAt
        self.size = size
    }

    public var name: String { location.lastPathComponent }

    /// When the holding area deletes it for good.
    public func expires(afterDays days: Int) -> Date { heldAt.addingTimeInterval(Double(days) * 86_400) }

    /// For Cleaner.undo, which puts it back.
    public var moved: MovedItem? {
        original.map { MovedItem(original: $0, inTrash: location, size: size) }
    }
}

public struct DeleteOutcome: Sendable {
    public var deleted: [HeldItem] = []
    public var failed: [FailedItem] = []
    public var bytes: Int64 { deleted.reduce(0) { $0 + $1.size } }
}

/// A folder Steward owns where cleaned items wait a few days before Steward
/// deletes them for good. Items can be put back until then. Use it in place of
/// the Trash when people want cleaning to free space without emptying the Trash.
///
/// Each item gets its own batch folder named with a UUID, holding the item and
/// a small note of where it came from. Steward only ever deletes batch folders
/// directly inside `folder`, and only ones named with a UUID.
public struct HoldingArea: TrashMover {
    public let folder: URL
    static let noteName = ".steward-held.json"

    struct Note: Codable {
        var original: String
        var heldAt: Date
    }

    public init(folder: URL) { self.folder = folder.standardizedFileURL }

    public func moveToTrash(_ url: URL) throws -> URL {
        try moveToTrash(url, now: .now)
    }

    public func moveToTrash(_ url: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        let batch = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: batch, withIntermediateDirectories: true)
        let dest = batch.appending(path: url.lastPathComponent)
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            try? fm.removeItem(at: batch)
            throw error
        }
        let note = Note(original: url.standardizedFileURL.path, heldAt: now)
        if let data = try? JSONEncoder().encode(note) {
            try? data.write(to: batch.appending(path: Self.noteName), options: .atomic)
        }
        return dest
    }

    /// Whether `url` is inside the holding area.
    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.path + "/")
    }

    /// Every held item, oldest first. Sizes each one, so call it off the main thread.
    public func items() -> [HeldItem] {
        let fm = FileManager.default
        var result: [HeldItem] = []
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where UUID(uuidString: name) != nil {
            let batch = folder.appending(path: name, directoryHint: .isDirectory)
            let children = ((try? fm.contentsOfDirectory(atPath: batch.path)) ?? []).filter { $0 != Self.noteName }
            guard let child = children.first else { continue }
            let location = batch.appending(path: child)
            let note = (try? Data(contentsOf: batch.appending(path: Self.noteName))).flatMap { try? JSONDecoder().decode(Note.self, from: $0) }
            let created = (try? batch.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            result.append(HeldItem(batch: batch, location: location, original: note.map { URL(fileURLWithPath: $0.original) },
                                   heldAt: note?.heldAt ?? created, size: Sizer.allocatedSize(of: location)))
        }
        return result.sorted { $0.heldAt < $1.heldAt }
    }

    /// Deletes items for good. Only batch folders Steward made are touched.
    public func delete(_ items: [HeldItem]) -> DeleteOutcome {
        var outcome = DeleteOutcome()
        for item in items {
            guard isBatch(item.batch), item.location.deletingLastPathComponent().standardizedFileURL.path == item.batch.standardizedFileURL.path else {
                outcome.failed.append(FailedItem(url: item.location, message: "Not in the holding area"))
                continue
            }
            do {
                try Self.forceRemove(item.batch)
                outcome.deleted.append(item)
            } catch {
                outcome.failed.append(FailedItem(url: item.location, message: Cleaner.describe(error)))
            }
        }
        return outcome
    }

    /// Deletes items held since before `cutoff`.
    public func purge(heldBefore cutoff: Date) -> DeleteOutcome {
        delete(items().filter { $0.heldAt < cutoff })
    }

    /// Removes batch folders whose item was put back.
    public func tidy() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where UUID(uuidString: name) != nil {
            let batch = folder.appending(path: name, directoryHint: .isDirectory)
            let children = ((try? fm.contentsOfDirectory(atPath: batch.path)) ?? []).filter { $0 != Self.noteName }
            if children.isEmpty { try? fm.removeItem(at: batch) }
        }
    }

    func isBatch(_ url: URL) -> Bool {
        let u = url.standardizedFileURL
        return u.deletingLastPathComponent().path == folder.path && UUID(uuidString: u.lastPathComponent) != nil
    }

    /// Removes a folder, first making read-only folders inside it writable
    /// (package caches often lock their files). Symlinks are removed, never followed.
    static func forceRemove(_ url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: url)
        } catch {
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                while let next = e.nextObject() as? URL {
                    let v = try? next.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if v?.isDirectory == true, v?.isSymbolicLink != true {
                        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: next.path)
                    }
                }
            }
            try fm.removeItem(at: url)
        }
    }
}

/// Empties the system Trash by asking Finder. macOS asks the person once to
/// let Steward control Finder.
public enum TrashControl {
    /// Returns an error message, or nil when the Trash was emptied.
    @MainActor
    public static func emptyTrash() -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        script?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
            return "Steward isn't allowed to control Finder. Turn it on in System Settings > Privacy & Security > Automation."
        }
        return (error[NSAppleScript.errorMessage] as? String) ?? "Finder couldn't empty the Trash."
    }
}
