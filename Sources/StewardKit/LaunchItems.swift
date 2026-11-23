import Foundation

/// A launchd job that starts at login or in the background.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable {
        /// ~/Library/LaunchAgents: Steward can turn these off.
        case user
        /// /Library/LaunchAgents: for every user; read-only here.
        case systemAgent
        /// /Library/LaunchDaemons: run as root; read-only here.
        case systemDaemon

        public var kind: String {
            switch self {
            case .user, .systemAgent: "Agent"
            case .systemDaemon: "Daemon"
            }
        }
    }

    public var id: String { plist.path }
    public let label: String
    public let plist: URL
    /// The program it runs: Program, or the first of ProgramArguments.
    public let program: String?
    public let scope: Scope
    /// The plist's own Disabled key.
    public let disabledInPlist: Bool

    public init(label: String, plist: URL, program: String?, scope: Scope, disabledInPlist: Bool) {
        self.label = label
        self.plist = plist
        self.program = program
        self.scope = scope
        self.disabledInPlist = disabledInPlist
    }

    public var isEditable: Bool { scope == .user }

    /// The .app that contains the program, if any.
    public var programApp: URL? {
        guard let program, let range = program.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
    }
}

public enum LaunchItems {
    public static func load(folder: URL, scope: LaunchItem.Scope) -> [LaunchItem] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".plist") }
            .compactMap { name in
                let url = folder.appending(path: name)
                guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
                let label = (dict["Label"] as? String) ?? String(name.dropLast(6))
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                return LaunchItem(label: label, plist: url, program: program, scope: scope,
                                  disabledInPlist: (dict["Disabled"] as? Bool) ?? false)
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// The app an item belongs to: the app containing its program, or the
    /// installed app whose bundle id starts its label.
    public static func owner(of item: LaunchItem, apps: [InstalledApp]) -> InstalledApp? {
        if let appURL = item.programApp {
            if let app = apps.first(where: { $0.url.standardizedFileURL.path == appURL.standardizedFileURL.path }) { return app }
        }
        let label = item.label.lowercased()
        return apps
            .filter { app in
                guard let id = app.bundleID?.lowercased() else { return false }
                return label == id || label.hasPrefix(id + ".")
            }
            .max { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }
    }
}

/// Turns user agents on and off. The real one calls launchctl; tests use FakeLaunchControl.
public protocol LaunchControl: Sendable {
    /// Labels turned off in the user's launchd domain.
    func disabledLabels() -> Set<String>
    func turnOff(_ item: LaunchItem) throws
    func turnOn(_ item: LaunchItem) throws
}

public struct LaunchControlError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// launchctl in the user's GUI domain. Turning off unloads the job and marks
/// it disabled, so it stays off after restart; turning on reverses both.
public struct SystemLaunchControl: LaunchControl {
    public init() {}

    var domain: String { "gui/\(getuid())" }

    public func disabledLabels() -> Set<String> {
        guard let out = try? run(["print-disabled", domain]) else { return [] }
        // Lines look like:  "com.vendor.agent" => disabled   (older: => true)
        var labels = Set<String>()
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return labels
    }

    public func turnOff(_ item: LaunchItem) throws {
        guard item.isEditable else { throw LaunchControlError(message: "Steward can't change system items.") }
        _ = try? run(["bootout", domain, item.plist.path])   // not loaded is fine
        try run(["disable", "\(domain)/\(item.label)"])
    }

    public func turnOn(_ item: LaunchItem) throws {
        guard item.isEditable else { throw LaunchControlError(message: "Steward can't change system items.") }
        try run(["enable", "\(domain)/\(item.label)"])
        _ = try? run(["bootstrap", domain, item.plist.path])  // already loaded is fine
    }

    @discardableResult
    func run(_ args: [String]) throws -> String {
        let result = try ProcessRunner.run("/bin/launchctl", args)
        guard result.status == 0 else {
            let msg = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchControlError(message: msg.isEmpty ? "launchctl \(args.first ?? "") failed" : msg)
        }
        return result.output
    }
}

/// In-memory launchd for tests and the self-test.
public final class FakeLaunchControl: LaunchControl, @unchecked Sendable {
    private let lock = NSLock()
    private var disabled = Set<String>()
    public init() {}
    public func disabledLabels() -> Set<String> { lock.withLock { disabled } }
    public func turnOff(_ item: LaunchItem) throws {
        guard item.isEditable else { throw LaunchControlError(message: "Steward can't change system items.") }
        _ = lock.withLock { disabled.insert(item.label) }
    }
    public func turnOn(_ item: LaunchItem) throws {
        guard item.isEditable else { throw LaunchControlError(message: "Steward can't change system items.") }
        _ = lock.withLock { disabled.remove(item.label) }
    }
}
