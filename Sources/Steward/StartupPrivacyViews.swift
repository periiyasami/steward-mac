import AppKit
import StewardKit
import SwiftUI

// MARK: - Background Activity

struct BackgroundView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bg = model.background
        Group {
            if bg.loading && bg.rows.isEmpty {
                ProgressView("Looking at background activity…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bg.visible.isEmpty {
                ContentUnavailableView("Nothing Running in the Background", systemImage: "moon.zzz",
                                       description: Text("No background jobs from your apps are running right now."))
            } else {
                List(bg.visible, selection: $bg.selection) { row in
                    BackgroundRow(row: row).tag(row.id)
                        .contextMenu {
                            if let id = row.loginItemID {
                                Button("Manage in Login Items") { model.loginItems.selection = id; model.sidebar = .loginItems }
                            }
                            if let path = row.process?.path, !path.isEmpty {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            }
                        }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("\(Count.items(bg.visible.count)) running · \(bg.stoppedCount) loaded but not running")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.md)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Background Activity")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Show Apple's Jobs", isOn: $bg.showsApple)
                    .help("Include jobs that are part of macOS")
                Button("Refresh", systemImage: "arrow.clockwise") { bg.load(loginItems: model.loginItems.rows) }
                    .help("Look at what is running again")
            }
        }
        .task {
            guard !Store.isOverridden else { return }
            if !model.loginItems.hasLoaded { model.loginItems.load() }
            if !bg.hasLoaded { bg.load(loginItems: model.loginItems.rows) }
        }
    }
}

struct BackgroundRow: View {
    let row: BackgroundModel.Row
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            if let url = row.appURL {
                AppIcon(url: url, size: 28)
            } else {
                Image(systemName: "gearshape.2").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text(row.appName == nil ? (row.process?.name ?? "") : row.job.label)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(row.job.label)
            }
            Spacer()
            if row.loginItemID != nil {
                Button("Login Items") { model.loginItems.selection = row.loginItemID; model.sidebar = .loginItems }
                    .buttonStyle(.link)
                    .help("This starts at login. Turn it off in Login Items.")
            }
            if let p = row.process {
                Text(Bytes.text(Int64(p.memory))).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Browser Data

struct BrowserDataView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.browserData
        Group {
            if b.loading && b.items.isEmpty {
                ProgressView("Looking for browser data…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if b.items.isEmpty && b.blocked.isEmpty {
                ContentUnavailableView("No Browser Data", systemImage: "safari",
                                       description: Text("Steward found no caches, cookies, or history from Safari, Chrome, Edge, Brave, Arc, or Firefox. Safari's history needs Full Disk Access."))
            } else {
                List {
                    if let message = b.message {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if !b.blocked.isEmpty {
                        AccessNote(text: "macOS protects some of \(b.blocked.joined(separator: ", "))'s data. Give Steward Full Disk Access to see cookies and history.")
                    }
                    ForEach(b.browsers, id: \.self) { browser in
                        Section {
                            ForEach(b.items(for: browser)) { item in
                                BrowserItemRow(item: item, ticked: b.ticked.contains(item.id)) { b.toggle(item) }
                            }
                        } header: {
                            HStack {
                                Text(browser)
                                if b.isRunning(browser) {
                                    Text("Open").font(.caption).foregroundStyle(.orange)
                                    Spacer()
                                    Button("Quit \(browser)") { b.quit(browser) }
                                        .buttonStyle(.link)
                                        .help("Ask \(browser) to quit so its data can be cleared")
                                }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    ReviewFooter(
                        selected: b.tickedItems.isEmpty ? "Nothing ticked"
                            : "\(Count.items(b.tickedItems.count)) ticked, \(Bytes.text(b.tickedItems.reduce(0) { $0 + $1.size }))",
                        canReview: !b.tickedItems.isEmpty
                    ) { model.openReviewForCurrentPage() }
                }
            }
        }
        .navigationTitle("Browser Data")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") { b.load() }
                    .help("Look for browser data again")
            }
        }
        .task { if !b.hasLoaded, !Store.isOverridden { b.load() } }
    }
}

struct BrowserItemRow: View {
    let item: BrowserItem
    let ticked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(get: { ticked }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(item.profile) \(item.kind.title)")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.kind.title) · \(item.profile)")
                Text(item.kind.effect).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Bytes.text(item.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.urls) }
        }
    }
}

// MARK: - Recent Items

struct RecentItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false

    var body: some View {
        let r = model.recentItems
        List {
            if let message = r.message {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if r.isBlocked {
                AccessNote(text: "macOS protects the recent-items lists. Give Steward Full Disk Access to clear them.")
            }
            Section {
                if r.lists.isEmpty && !r.isBlocked {
                    Text("No recent-items lists found.").foregroundStyle(.secondary)
                }
                ForEach(r.lists) { list in
                    HStack(spacing: Space.md) {
                        Toggle(isOn: Binding(get: { r.ticked.contains(list.id) },
                                             set: { on in if on { r.ticked.insert(list.id) } else { r.ticked.remove(list.id) } })) { EmptyView() }
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel(list.title)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.title)
                            Text(list.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let date = list.modified {
                            Text("Updated \(date.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Recent Items Lists")
            } footer: {
                Text("macOS starts each list again, empty, after it moves to the Trash.").foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Look Thumbnails")
                        Text("Small previews of files you browsed, kept by macOS.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Thumbnails…") { confirmingReset = true }
                }
            } header: {
                Text("Previews")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ReviewFooter(selected: r.ticked.isEmpty ? "Nothing ticked" : "\(Count.items(r.ticked.count)) ticked",
                         canReview: !r.ticked.isEmpty) { model.openReviewForCurrentPage() }
        }
        .confirmationDialog("Reset Quick Look Thumbnails?", isPresented: $confirmingReset) {
            Button("Reset Thumbnails") { Task { await r.runQuickLookReset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS makes new thumbnails as you browse. This can't be undone.")
        }
        .navigationTitle("Recent Items")
        .task { if !r.hasLoaded, !Store.isOverridden { r.load() } }
    }
}

/// A row that says why something is missing and how to fix it.
struct AccessNote: View {
    let text: String

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "lock.shield").foregroundStyle(Palette.accentText).accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Button("Open System Settings") { SystemSettings.openFullDiskAccess() }
        }
        .padding(.vertical, Space.xs)
    }
}
