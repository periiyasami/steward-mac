import AppKit
import Foundation
import Observation
import StewardKit

/// Jobs running right now in this user's launchd domain.
@Observable
final class BackgroundModel {
    struct Row: Identifiable, Hashable {
        var id: String { job.label }
        let job: LaunchJob
        let process: ProcessSample?
        let appName: String?
        let appURL: URL?
        /// The matching Login Items row, when the job comes from the user's LaunchAgents.
        let loginItemID: String?
        var name: String { appName ?? job.label }
    }

    let appFolders: [URL]
    let home: URL
    var rows: [Row] = []
    var showsApple = Prefs.showApple
    var loading = false
    var hasLoaded = false
    var selection: String?

    init(home: URL, appFolders: [URL]) {
        self.home = home
        self.appFolders = appFolders
    }

    var visible: [Row] {
        rows.filter { $0.job.isRunning && (showsApple || !$0.job.isApple) }
            .sorted { ($0.process?.memory ?? 0) > ($1.process?.memory ?? 0) }
    }

    var stoppedCount: Int { rows.filter { !$0.job.isRunning && (showsApple || !$0.job.isApple) }.count }

    /// `jobs` is injectable for the self-test; by default it reads `launchctl list`.
    func load(loginItems: [LoginItemsModel.Row], jobs: (@Sendable () -> [LaunchJob])? = nil) {
        loading = true
        hasLoaded = true
        let folders = appFolders, home = home
        let userAgents = Dictionary(loginItems.filter { $0.item.scope == .user }.map { ($0.item.label, $0.id) }, uniquingKeysWith: { a, _ in a })
        let read = jobs ?? { LaunchJob.list() }
        Task {
            let loaded: [Row] = await Task.detached {
                let apps = AppCatalog.installedApps(in: folders, home: home)
                return read().map { job in
                    let process = job.pid.flatMap { ProcessSample.read(pid: $0) }
                    var app: InstalledApp?
                    if let id = job.applicationBundleID { app = apps.first { $0.bundleID == id } }
                    if app == nil, let path = process?.appPath { app = apps.first { $0.url.path == path } }
                    if app == nil {
                        let item = LaunchItem(label: job.label, plist: URL(fileURLWithPath: "/"), program: process?.path, scope: .user, disabledInPlist: false)
                        app = LaunchItems.owner(of: item, apps: apps)
                    }
                    return Row(job: job, process: process, appName: app?.name, appURL: app?.url, loginItemID: userAgents[job.label])
                }
            }.value
            rows = loaded
            loading = false
        }
    }

    func loadSample() {
        func r(_ label: String, _ pid: Int32?, _ name: String?, _ mem: UInt64, login: Bool = false) -> Row {
            Row(job: LaunchJob(label: label, pid: pid, lastExitStatus: 0),
                process: pid.map { ProcessSample(pid: $0, path: "/Applications/\(name ?? "x").app/Contents/MacOS/agent", memory: mem, cpuTime: 0) },
                appName: name, appURL: name.map { URL(fileURLWithPath: "/Applications/\($0).app") },
                loginItemID: login ? "/Users/me/Library/LaunchAgents/\(label).plist" : nil)
        }
        rows = [r("application.com.tinyspeck.slackmacgap.4021", 812, "Slack", 412_000_000),
                r("com.docker.helper", 640, "Docker", 286_000_000),
                r("com.google.keystone.agent", 733, nil, 18_400_000, login: true),
                r("com.spotify.webhelper", 902, "Spotify", 42_000_000, login: true),
                r("us.zoom.updater.login.check", nil, "Zoom", 0, login: true),
                r("com.apple.Finder", 455, "Finder", 210_000_000)]
        hasLoaded = true
        loading = false
    }
}
