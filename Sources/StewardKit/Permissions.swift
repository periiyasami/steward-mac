import Foundation
import SQLite3

/// A privacy permission macOS keeps in its TCC database.
public enum PrivacyService: String, CaseIterable, Sendable {
    case camera = "kTCCServiceCamera"
    case microphone = "kTCCServiceMicrophone"
    case screenCapture = "kTCCServiceScreenCapture"
    case accessibility = "kTCCServiceAccessibility"
    case fullDisk = "kTCCServiceSystemPolicyAllFiles"
    case inputMonitoring = "kTCCServiceListenEvent"
    case automation = "kTCCServiceAppleEvents"
    case contacts = "kTCCServiceAddressBook"
    case calendars = "kTCCServiceCalendar"
    case reminders = "kTCCServiceReminders"
    case photos = "kTCCServicePhotos"
    case desktop = "kTCCServiceSystemPolicyDesktopFolder"
    case documents = "kTCCServiceSystemPolicyDocumentsFolder"
    case downloads = "kTCCServiceSystemPolicyDownloadsFolder"

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenCapture: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        case .fullDisk: "Full Disk Access"
        case .inputMonitoring: "Input Monitoring"
        case .automation: "Automation"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .photos: "Photos"
        case .desktop: "Desktop Folder"
        case .documents: "Documents Folder"
        case .downloads: "Downloads Folder"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .screenCapture: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .fullDisk: "internaldrive"
        case .inputMonitoring: "keyboard"
        case .automation: "gearshape.2"
        case .contacts: "person.crop.circle"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .photos: "photo.on.rectangle"
        case .desktop, .documents, .downloads: "folder"
        }
    }

    /// The System Settings anchor for this service.
    public var settingsAnchor: String {
        switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenCapture: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .fullDisk: "Privacy_AllFiles"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .automation: "Privacy_Automation"
        case .contacts: "Privacy_Contacts"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .photos: "Privacy_Photos"
        case .desktop, .documents, .downloads: "Privacy_FilesAndFolders"
        }
    }
}

/// One app's answer for one service.
public struct PermissionGrant: Sendable, Hashable, Identifiable {
    public var id: String { "\(service.rawValue)|\(client)" }
    public let service: PrivacyService
    /// A bundle id, or a path for command-line tools.
    public let client: String
    public let isPath: Bool
    public let allowed: Bool
    public let lastModified: Date?

    public init(service: PrivacyService, client: String, isPath: Bool, allowed: Bool, lastModified: Date?) {
        self.service = service
        self.client = client
        self.isPath = isPath
        self.allowed = allowed
        self.lastModified = lastModified
    }
}

public enum TCCReader {
    public enum ReadError: Error { case cannotOpen, cannotQuery }

    /// The user's database. The system one is at /Library/Application Support/com.apple.TCC/TCC.db.
    public static func userDatabase(home: URL) -> URL {
        home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
    }

    public static let systemDatabase = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")

    /// Reads grants read-only. Both databases need Full Disk Access.
    public static func read(_ db: URL) throws -> [PermissionGrant] {
        // Plain read-only sees changes macOS hasn't checkpointed yet. It needs to
        // open the write-ahead log, so fall back to immutable when that's refused.
        do {
            return try read(uri: "file:\(db.path)?mode=ro")
        } catch {
            return try read(uri: "file:\(db.path)?mode=ro&immutable=1")
        }
    }

    static func read(uri: String) throws -> [PermissionGrant] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ReadError.cannotOpen
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        // auth_value: 0 denied, 2 allowed, 3 limited. Older systems used an `allowed` column instead.
        let modern = "SELECT service, client, client_type, auth_value, last_modified FROM access"
        let legacy = "SELECT service, client, client_type, allowed * 2, last_modified FROM access"
        if sqlite3_prepare_v2(handle, modern, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            guard sqlite3_prepare_v2(handle, legacy, -1, &stmt, nil) == SQLITE_OK else { throw ReadError.cannotQuery }
        }
        defer { sqlite3_finalize(stmt) }
        var grants: [PermissionGrant] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let s = sqlite3_column_text(stmt, 0), let c = sqlite3_column_text(stmt, 1),
                  let service = PrivacyService(rawValue: String(cString: s)) else { continue }
            let auth = sqlite3_column_int(stmt, 3)
            let modified = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
            grants.append(PermissionGrant(service: service, client: String(cString: c), isPath: sqlite3_column_int(stmt, 2) == 1,
                                          allowed: auth >= 2, lastModified: modified))
        }
        return grants
    }
}
