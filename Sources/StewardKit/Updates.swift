import Foundation

/// Compares version strings numerically, part by part: 1.10 > 1.9, 2.0 == 2.
public enum Version {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

/// The newest item in a Sparkle appcast.
public struct AppcastItem: Sendable, Equatable {
    public let version: String
    public let title: String?
    public init(version: String, title: String?) {
        self.version = version
        self.title = title
    }
}

/// Reads a Sparkle appcast and returns its newest version.
public final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var inItem = false
    private var text = ""
    private var title: String?
    private var shortVersion: String?
    private var buildVersion: String?

    public static func newest(in data: Data) -> AppcastItem? {
        let p = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !p.items.isEmpty else { return nil }
        return p.items.max { Version.compare($0.version, $1.version) == .orderedAscending }
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        text = ""
        if name == "item" {
            inItem = true
            title = nil
            shortVersion = nil
            buildVersion = nil
        }
        if inItem, name == "enclosure" {
            shortVersion = shortVersion ?? attributes["sparkle:shortVersionString"]
            buildVersion = buildVersion ?? attributes["sparkle:version"]
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": title = value
        case "sparkle:shortVersionString": shortVersion = value
        case "sparkle:version": buildVersion = value
        case "item":
            inItem = false
            if let v = shortVersion ?? buildVersion, !v.isEmpty { items.append(AppcastItem(version: v, title: title)) }
        default: break
        }
    }
}

/// What Steward knows about an app's updates.
public struct UpdateSource: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, Hashable {
        case appStore
        /// A Sparkle appcast.
        case sparkle(URL)
        /// electron-updater's generic server: the folder holding latest-mac.yml.
        case electron(URL)
        /// electron-updater with GitHub releases.
        case github(owner: String, repo: String)
        /// Installed with Homebrew: the cask's token and the version Homebrew installed.
        case homebrew(token: String, installed: String)
        case unknown

        /// Whether Steward can ask a server for the newest version.
        public var isCheckable: Bool {
            switch self {
            case .sparkle, .electron, .github, .homebrew: true
            case .appStore, .unknown: false
            }
        }

        /// How Steward checks, for the row's subtitle.
        public var via: String? {
            switch self {
            case .sparkle: "Sparkle"
            case .electron: "Electron updater"
            case .github: "GitHub releases"
            case .homebrew: "Homebrew"
            case .appStore, .unknown: nil
            }
        }

        /// The URL Steward fetches. Only https, and file for tests.
        public var requestURL: URL? {
            switch self {
            case .sparkle(let url): return url
            case .electron(let base): return base.appending(path: "latest-mac.yml")
            case .github(let owner, let repo): return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
            case .homebrew(let token, _): return URL(string: "https://formulae.brew.sh/api/cask/\(token).json")
            case .appStore, .unknown: return nil
            }
        }

        /// The newest version in a fetched response.
        public func newestVersion(in data: Data) -> String? {
            switch self {
            case .sparkle: return AppcastParser.newest(in: data)?.version
            case .electron: return SimpleYAML.parse(String(decoding: data, as: UTF8.self))["version"]
            case .github:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else { return nil }
                return tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
            case .homebrew:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["version"] as? String, version != "latest" else { return nil }
                return version
            case .appStore, .unknown: return nil
            }
        }

        /// The version to compare with when the source knows it better than the
        /// app's Info.plist (Homebrew versions can carry a build: "1.2,345").
        public var installedVersion: String? {
            if case .homebrew(_, let installed) = self { return installed }
            return nil
        }
    }

    public let kind: Kind
    public let currentVersion: String?

    public init(kind: Kind, currentVersion: String?) {
        self.kind = kind
        self.currentVersion = currentVersion
    }

    /// Reads the app's Info.plist, receipt, and updater files to see how it
    /// updates. `casks` comes from HomebrewCasks.index. No network.
    public static func of(app: URL, casks: [String: CaskInfo] = [:]) -> UpdateSource {
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        if FileManager.default.fileExists(atPath: app.appending(path: "Contents/_MASReceipt/receipt").path) {
            return UpdateSource(kind: .appStore, currentVersion: version)
        }
        if let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), ["https", "file"].contains(url.scheme ?? "") {
            return UpdateSource(kind: .sparkle(url), currentVersion: version)
        }
        if let kind = electronKind(app: app) {
            return UpdateSource(kind: kind, currentVersion: version)
        }
        if let cask = casks[app.lastPathComponent] {
            return UpdateSource(kind: .homebrew(token: cask.token, installed: cask.version), currentVersion: version)
        }
        return UpdateSource(kind: .unknown, currentVersion: version)
    }

    /// electron-updater keeps its server in Contents/Resources/app-update.yml.
    static func electronKind(app: URL) -> Kind? {
        let file = app.appending(path: "Contents/Resources/app-update.yml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let yaml = SimpleYAML.parse(text)
        switch yaml["provider"] {
        case "generic":
            guard let raw = yaml["url"], let url = URL(string: raw), ["https", "file"].contains(url.scheme ?? "") else { return nil }
            return .electron(url)
        case "github":
            guard let owner = yaml["owner"], let repo = yaml["repo"],
                  [owner, repo].allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
            else { return nil }
            return .github(owner: owner, repo: repo)
        default:
            return nil
        }
    }
}

/// Top-level "key: value" lines of a YAML file. Enough for updater files.
public enum SimpleYAML {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty, result[key] == nil { result[key] = value }
        }
        return result
    }
}

/// A Homebrew cask: its token and the version Homebrew installed.
public struct CaskInfo: Sendable, Hashable {
    public let token: String
    public let version: String
    public init(token: String, version: String) {
        self.token = token
        self.version = version
    }

    /// The command that updates it, to paste into Terminal.
    public var upgradeCommand: String { "brew upgrade --cask \(token)" }
}

/// Which apps Homebrew installed, read from its Caskroom. No brew command runs.
public enum HomebrewCasks {
    public static let defaultCaskrooms = [URL(fileURLWithPath: "/opt/homebrew/Caskroom"), URL(fileURLWithPath: "/usr/local/Caskroom")]

    /// App bundle names ("Visual Studio Code.app") to their cask.
    public static func index(caskrooms: [URL] = defaultCaskrooms) -> [String: CaskInfo] {
        let fm = FileManager.default
        var result: [String: CaskInfo] = [:]
        for room in caskrooms {
            for token in (try? fm.contentsOfDirectory(atPath: room.path)) ?? [] where !token.hasPrefix(".") {
                let dir = room.appending(path: token)
                let versions = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
                guard let version = versions.max(by: { Version.compare($0, $1) == .orderedAscending }), version != "latest" else { continue }
                for app in appNames(token: token, in: dir.appending(path: ".metadata")) where result[app] == nil {
                    result[app] = CaskInfo(token: token, version: version)
                }
            }
        }
        return result
    }

    /// The .app names in the cask's saved definition (<token>.json or <token>.rb under .metadata).
    static func appNames(token: String, in metadata: URL) -> Set<String> {
        guard let e = FileManager.default.enumerator(at: metadata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var names = Set<String>()
        while let url = e.nextObject() as? URL {
            if e.level > 5 { e.skipDescendants(); continue }
            let file = url.lastPathComponent
            if file == "\(token).json", let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                collectApps(json["artifacts"], into: &names)
            } else if file == "\(token).rb", let text = try? String(contentsOf: url, encoding: .utf8) {
                names.formUnion(rubyApps(text))
            }
        }
        return names
    }

    static func collectApps(_ value: Any?, into names: inout Set<String>) {
        if let s = value as? String {
            if s.hasSuffix(".app") { names.insert((s as NSString).lastPathComponent) }
        } else if let array = value as? [Any] {
            array.forEach { collectApps($0, into: &names) }
        } else if let dict = value as? [String: Any] {
            // Only "app" artifacts and their targets, never "uninstall" or "zap" paths.
            for (key, v) in dict where key == "app" || key == "target" { collectApps(v, into: &names) }
        }
    }

    /// `app "Name.app"` and `target: "Other.app"` in a cask's Ruby file.
    static func rubyApps(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("app ") else { continue }
            for part in t.split(separator: "\"", omittingEmptySubsequences: false).enumerated() where part.offset % 2 == 1 {
                let s = String(part.element)
                if s.hasSuffix(".app") { names.insert((s as NSString).lastPathComponent) }
            }
        }
        return names
    }
}
