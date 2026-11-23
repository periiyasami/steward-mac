import AppKit
import Foundation
import Observation
import StewardKit

/// State for Login Items: launch agents and daemons with the app each belongs to.
@Observable
final class LoginItemsModel {
    struct Row: Identifiable, Hashable {
        var id: String { item.id }
        let item: LaunchItem
        let owner: InstalledApp?
        var isOn: Bool
        var name: String { owner?.name ?? item.label }
    }

    let home: URL
    let control: LaunchControl
    let systemFolders: [(URL, LaunchItem.Scope)]
    let appFolders: [URL]
    var rows: [Row] = []
    var loading = false
    var hasLoaded = false
    /// Shown above the list when turning an item on or off fails.
    var message: String?
    var selection: String?

    init(home: URL, control: LaunchControl, systemFolders: [(URL, LaunchItem.Scope)], appFolders: [URL]) {
        self.home = home
        self.control = control
        self.systemFolders = systemFolders
        self.appFolders = appFolders
    }

    var userRows: [Row] { rows.filter { $0.item.scope == .user } }
    var systemRows: [Row] { rows.filter { $0.item.scope != .user } }

    func load() {
        loading = true
        hasLoaded = true
        let home = home, control = control, systemFolders = systemFolders, appFolders = appFolders
        Task {
            let loaded: [Row] = await Task.detached {
                let apps = AppCatalog.installedApps(in: appFolders, home: home)
                let disabled = control.disabledLabels()
                var items = LaunchItems.load(folder: home.appending(path: "Library/LaunchAgents"), scope: .user)
                for (folder, scope) in systemFolders { items += LaunchItems.load(folder: folder, scope: scope) }
                return items.map { item in
                    Row(item: item, owner: LaunchItems.owner(of: item, apps: apps),
                        isOn: !item.disabledInPlist && !disabled.contains(item.label))
                }
            }.value
            rows = loaded
            loading = false
        }
    }

    func setOn(_ row: Row, _ on: Bool) {
        guard row.item.isEditable else { return }
        message = nil
        do {
            if on { try control.turnOn(row.item) } else { try control.turnOff(row.item) }
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].isOn = on }
        } catch {
            message = "Couldn't turn \(on ? "on" : "off") \(row.name): \(error.localizedDescription)"
        }
    }

    /// Review for moving a user agent's file to the Trash. It is turned off first.
    func trashSession(_ row: Row) -> ReviewSession? {
        guard row.item.isEditable else { return nil }
        if row.isOn { setOn(row, false) }
        let size = Sizer.allocatedSize(of: row.item.plist)
        return ReviewSession(source: .loginItems, rows: [
            Candidate(url: row.item.plist, size: size, reason: "Starts \(row.name) at login", group: "Login Item"),
        ])
    }

    func removed(_ paths: Set<String>) {
        rows.removeAll { paths.contains($0.id) }
    }

    func restored() {
        if hasLoaded, !Store.isOverridden { load() }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Snapshot sample

    func loadSample() {
        let la = home.appending(path: "Library/LaunchAgents")
        func app(_ name: String, _ id: String) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, version: nil, teamID: nil, isLocked: false)
        }
        func row(_ label: String, _ scope: LaunchItem.Scope, _ owner: InstalledApp?, _ on: Bool, folder: URL? = nil) -> Row {
            let dir = folder ?? la
            return Row(item: LaunchItem(label: label, plist: dir.appending(path: "\(label).plist"), program: nil, scope: scope, disabledInPlist: false),
                       owner: owner, isOn: on)
        }
        let sysAgents = URL(fileURLWithPath: "/Library/LaunchAgents")
        let daemons = URL(fileURLWithPath: "/Library/LaunchDaemons")
        rows = [
            row("com.google.keystone.agent", .user, nil, true),
            row("com.spotify.webhelper", .user, app("Spotify", "com.spotify.client"), false),
            row("com.tinyspeck.slackmacgap.updater", .user, app("Slack", "com.tinyspeck.slackmacgap"), true),
            row("us.zoom.updater.login.check", .user, app("Zoom", "us.zoom.xos"), true),
            row("com.microsoft.update.agent", .systemAgent, nil, true, folder: sysAgents),
            row("com.docker.vmnetd", .systemDaemon, app("Docker", "com.docker.docker"), true, folder: daemons),
        ]
        hasLoaded = true
        loading = false
        message = nil
    }
}
