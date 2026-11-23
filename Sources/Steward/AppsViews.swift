import AppKit
import StewardKit
import SwiftUI

// MARK: - Unused Apps

struct UnusedAppsView: View {
    @Environment(AppModel.self) private var model
    @State private var period: UnusedPeriod = UnusedPeriod(rawValue: Prefs.unusedPeriod) ?? .six
    @State private var selection: String?

    var body: some View {
        let un = model.uninstaller
        let rows = un.unused(period)
        Group {
            if un.loading && un.rows.isEmpty {
                ProgressView("Looking for apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No Unused Apps", systemImage: "checkmark.circle",
                                       description: Text("Every app you can remove was opened in the last \(period.rawValue) months."))
            } else {
                List(rows, selection: $selection) { row in
                    HStack(spacing: Space.md) {
                        AppIcon(url: row.app.url, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.app.name)
                            Text(row.lastUsed.map { "Last opened \($0.formatted(.relative(presentation: .named)))" } ?? "Never opened on this Mac")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let total = row.total {
                            Text(Bytes.text(total)).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Button("Uninstall…") { uninstall(row) }
                            .help("Review \(row.app.name) and its leftovers before they move to the Trash")
                    }
                    .padding(.vertical, 2)
                    .tag(row.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.app.url]) }
                        Button("Show in Uninstaller") { un.mode = .apps; un.selection = row.id; model.sidebar = .uninstaller }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("\(Count.items(rows.count)) · \(Bytes.text(rows.reduce(0) { $0 + ($1.total ?? 0) })) could be freed")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.md)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Unused Apps")
        .toolbar {
            ToolbarItem {
                Picker("Period", selection: $period) {
                    ForEach(UnusedPeriod.allCases) { Text($0.title).tag($0) }
                }
                .help("How long since an app was last opened")
            }
        }
        .task { if !un.hasLoaded, !Store.isOverridden { un.load() } }
    }

    private func uninstall(_ row: UninstallerModel.AppRow) {
        let un = model.uninstaller
        un.selection = row.id
        Task {
            while un.loadingLeftovers { try? await Task.sleep(for: .milliseconds(50)) }
            model.review = await un.uninstallSession()
        }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.permissions
        Group {
            if p.loading && p.rows.isEmpty {
                ProgressView("Reading permissions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if p.isLocked {
                ContentUnavailableView {
                    Label("Permissions Need Full Disk Access", systemImage: "lock.shield")
                } description: {
                    Text("macOS keeps privacy permissions in a protected file. Give Steward Full Disk Access to list them here. Steward only reads them.")
                } actions: {
                    Button("Open System Settings") { SystemSettings.openFullDiskAccess() }
                        .buttonStyle(.borderedProminent)
                }
            } else if p.rows.isEmpty {
                ContentUnavailableView("No Permissions", systemImage: "hand.raised",
                                       description: Text("No app has asked for a privacy permission yet."))
            } else {
                List {
                    ForEach(p.services, id: \.self) { service in
                        Section {
                            ForEach(p.rows(for: service)) { PermissionRow(row: $0) }
                        } header: {
                            HStack {
                                Label(service.title, systemImage: service.symbol)
                                Spacer()
                                Button("Open in System Settings") { PermissionsModel.openSettings(for: service) }
                                    .buttonStyle(.link)
                                    .font(.callout)
                                    .help("Change who has \(service.title) in Privacy & Security")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Permissions")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { p.load() }
                    .help("Read permissions again")
            }
        }
        .task { if !p.hasLoaded, !Store.isOverridden { p.load() } }
    }
}

struct PermissionRow: View {
    let row: PermissionsModel.Row

    var body: some View {
        HStack(spacing: Space.md) {
            if row.grant.isPath {
                Image(nsImage: NSWorkspace.shared.icon(for: .unixExecutable))
                    .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
            } else {
                AppIcon(url: row.appURL ?? URL(fileURLWithPath: "/nonexistent.app"), size: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                if row.grant.isPath || row.appURL == nil {
                    Text(row.grant.client).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Label(row.grant.allowed ? "Allowed" : "Denied", systemImage: row.grant.allowed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(row.grant.allowed ? Palette.accentText : .secondary)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Updates

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.Key.updatesAllowed, store: Prefs.store) private var allowed = false

    var body: some View {
        let u = model.updates
        List {
            if !allowed {
                Section {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Update checks are off").font(.headline)
                        Text("To check, Steward contacts each app maker's update server. Nothing about you or Steward is sent, and nothing is fetched until you press Check for Updates.")
                            .foregroundStyle(.secondary)
                        Toggle("Allow Update Checks", isOn: $allowed)
                    }
                    .padding(.vertical, Space.xs)
                }
            }
            if !u.available.isEmpty {
                Section("Updates Available") {
                    ForEach(u.available) { UpdateRow(row: $0) }
                }
            }
            Section {
                ForEach(u.checkable.filter { if case .available = $0.state { false } else { true } }) { UpdateRow(row: $0) }
            } header: {
                Text("Checked by Steward")
            } footer: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let date = u.lastChecked {
                        Text("Last checked \(date.formatted(.relative(presentation: .named))).")
                    }
                    Text("Steward reads Sparkle feeds, Electron updater servers, GitHub releases, and Homebrew's cask list.")
                }
                .foregroundStyle(.secondary)
            }
            Section("Updated Another Way") {
                ForEach(u.others) { UpdateRow(row: $0) }
            }
        }
        .navigationTitle("Updates")
        .safeAreaInset(edge: .bottom) {
            if let message = u.message {
                HStack {
                    Text(message).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.md)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Copy Homebrew Commands", systemImage: "doc.on.clipboard") { u.copy(u.brewUpgrades) }
                    .disabled(u.brewUpgrades.isEmpty)
                    .help("Copy brew upgrade commands for every Homebrew app with an update")
            }
            ToolbarItem {
                Button(u.checking ? "Checking…" : "Check for Updates", systemImage: "arrow.down.circle") {
                    Task { await u.checkAll(allowed: allowed) }
                }
                .disabled(!allowed || u.checking || u.checkable.isEmpty)
                .help(allowed ? "Ask each app's update server for its newest version" : "Turn on Allow Update Checks first")
            }
        }
        .task {
            guard !Store.isOverridden else { return }
            if !model.uninstaller.hasLoaded { model.uninstaller.load() }
            while model.uninstaller.loading { try? await Task.sleep(for: .milliseconds(50)) }
            if !u.hasLoaded { u.load(apps: model.uninstaller.rows.map(\.app)) }
        }
    }
}

struct UpdateRow: View {
    let row: UpdatesModel.Row
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            AppIcon(url: row.url, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                Text([row.current.map { "Version \($0)" } ?? "Unknown version", row.kind.via.map { "via \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            status
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch row.state {
        case .notChecked: Text("Not checked").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let v):
            HStack(spacing: Space.sm) {
                Text("Version \(v)").foregroundStyle(Palette.accentText)
                if let command = row.brewCommand {
                    Button("Copy Command") { model.updates.copy([command]) }
                        .help("Copy \(command) to paste into Terminal")
                } else {
                    Button("Open App") { NSWorkspace.shared.open(row.url) }
                        .help("Open \(row.name); most apps offer the update when they start")
                }
            }
        case .failed(let message): Text(message).foregroundStyle(.secondary)
        case .appStore:
            Button("Updated by the App Store") {
                if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
        case .noFeed: Text("Updates itself").foregroundStyle(.secondary)
        }
    }
}
