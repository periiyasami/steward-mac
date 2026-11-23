import AppKit
import StewardKit
import SwiftUI

struct UninstallerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var un = model.uninstaller
        VStack(spacing: 0) {
            Picker("Show", selection: $un.mode) {
                Text("Installed Apps").tag(UninstallerModel.Mode.apps)
                Text("Leftovers of Removed Apps").tag(UninstallerModel.Mode.leftovers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, Space.sm)
            .help("Show installed apps, or files left behind by apps that are gone")
            Divider()
            switch un.mode {
            case .apps: AppsPane(un: un)
            case .leftovers: OrphansPane(un: un)
            }
        }
        .navigationTitle("Uninstaller")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") {
                    if un.mode == .apps { un.load() } else { un.loadOrphans() }
                }
                .help("Look for apps and leftovers again")
            }
        }
        .task(id: un.mode) {
            guard !Store.isOverridden else { return }
            if !un.hasLoaded { un.load() }
            if un.mode == .leftovers, !un.hasLoadedOrphans {
                while un.loading { try? await Task.sleep(for: .milliseconds(50)) }
                un.loadOrphans()
            }
        }
    }
}

// MARK: - Apps

struct AppsPane: View {
    @Bindable var un: UninstallerModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search Apps", text: $un.search, prompt: Text("Search Apps"))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .accessibilityLabel("Search apps")
                List(un.filtered, selection: $un.selection) { row in
                    AppRowView(row: row).tag(row.id)
                }
            }
            .overlay {
                if un.loading && un.rows.isEmpty {
                    ProgressView("Looking for apps…")
                } else if un.filtered.isEmpty && !un.search.isEmpty {
                    ContentUnavailableView.search(text: un.search)
                }
            }
            .frame(width: 320)
            Divider()
            if let row = un.selected {
                AppDetail(un: un, row: row)
            } else {
                ContentUnavailableView("No App Selected", systemImage: "app.dashed",
                                       description: Text("Choose an app to see its size and the files it keeps."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct AppRowView: View {
    let row: UninstallerModel.AppRow

    var body: some View {
        HStack(spacing: Space.md) {
            AppIcon(url: row.app.url, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(row.app.name).lineLimit(1)
                    if row.app.isLocked {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Steward can't remove this app")
                            .accessibilityLabel("Locked")
                    }
                }
                Group {
                    if let used = row.lastUsed {
                        Text("Used \(used, format: .relative(presentation: .named))")
                    } else {
                        Text(row.app.version.map { "Version \($0)" } ?? " ")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.sm)
            if let total = row.total {
                Text(Bytes.text(total)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct AppIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        let path = url.path
        let image = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        Image(nsImage: image)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AppDetail: View {
    @Bindable var un: UninstallerModel
    let row: UninstallerModel.AppRow
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.lg) {
                AppIcon(url: row.app.url, size: 64)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(row.app.name).font(.title2.bold())
                    Text([row.app.version.map { "Version \($0)" }, row.app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let bundle = row.bundleSize {
                        Text("App \(Bytes.text(bundle)) · Leftovers \(Bytes.text(un.leftovers.reduce(0) { $0 + $1.size }))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Button(un.quitting ? "Quitting \(row.app.name)…" : "Uninstall…") {
                        Task { model.review = await un.uninstallSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!un.canUninstall)
                    .help(row.app.isLocked ? "Steward can't remove Apple's apps or apps you don't have permission to move"
                                           : "Review the app and its leftovers before they move to the Trash (⌘↩)")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.app.url]) }
                        .buttonStyle(.link)
                }
            }
            .padding(Space.margin)

            if let message = un.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Space.margin)
                    .padding(.bottom, Space.md)
            }
            if row.app.isLocked {
                Label("Steward can't remove Apple's apps or apps you don't have permission to move.", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.margin)
                    .padding(.bottom, Space.md)
            }
            Divider()
            if un.loadingLeftovers {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if un.leftovers.isEmpty {
                ContentUnavailableView("No Leftovers Found", systemImage: "checkmark.circle",
                                       description: Text("\(row.app.name) keeps no files Steward can find outside the app."))
            } else {
                List {
                    ForEach(un.leftoverLocations, id: \.self) { location in
                        Section(location) {
                            ForEach(un.leftovers.filter { $0.location == location }) { l in
                                LeftoverRow(leftover: l, ticked: un.leftoverTicks.contains(l.id)) { un.toggleLeftover(l) }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LeftoverRow: View {
    let leftover: Leftover
    let ticked: Bool
    /// App leftovers mark name-only matches; leftovers of removed apps are all unconfirmed, so the group says it once.
    var marksPossible = true
    let toggle: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(get: { ticked }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(leftover.url.lastPathComponent)
            Text(model.display(leftover.url))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.display(leftover.url))
            if marksPossible && !leftover.isCertain {
                Text("Possible match")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.14)))
                    .help("Matched by name only. Check it belongs to this app before you tick it.")
            }
            Spacer(minLength: Space.md)
            Text(Bytes.text(leftover.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([leftover.url]) }
        }
    }
}

// MARK: - Leftovers of removed apps

struct OrphansPane: View {
    @Bindable var un: UninstallerModel
    @Environment(AppModel.self) private var model

    var body: some View {
        if un.loadingOrphans || (un.loading && !un.hasLoadedOrphans) {
            ProgressView("Looking for leftovers…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if un.orphans.isEmpty {
            ContentUnavailableView("No Leftovers", systemImage: "checkmark.circle",
                                   description: Text("Steward found no files from apps that are no longer installed."))
        } else {
            List {
                Section {
                    ForEach(un.orphanGroups, id: \.owner) { group in
                        OrphanGroupView(un: un, owner: group.owner, items: group.items)
                    }
                } footer: {
                    Text("Each group is named after an app id no installed app uses. Nothing is ticked for you: check each group before you tick it.")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ReviewFooter(
                    selected: un.tickedOrphans.isEmpty ? "Nothing ticked"
                        : "\(Count.items(un.tickedOrphans.count)) ticked, \(Bytes.text(un.tickedOrphans.reduce(0) { $0 + $1.size }))",
                    canReview: !un.tickedOrphans.isEmpty
                ) { model.openReviewForCurrentPage() }
            }
        }
    }
}

struct OrphanGroupView: View {
    @Bindable var un: UninstallerModel
    let owner: String
    let items: [Leftover]

    var body: some View {
        DisclosureGroup {
            ForEach(items) { l in
                LeftoverRow(leftover: l, ticked: un.orphanTicks.contains(l.id), marksPossible: false) {
                    if un.orphanTicks.contains(l.id) { un.orphanTicks.remove(l.id) } else { un.orphanTicks.insert(l.id) }
                }
            }
        } label: {
            HStack(spacing: Space.md) {
                Toggle(sources: items.map { l in
                    Binding(get: { un.orphanTicks.contains(l.id) },
                            set: { on in if on { un.orphanTicks.insert(l.id) } else { un.orphanTicks.remove(l.id) } })
                }, isOn: \.self) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(owner)
                Image(systemName: "questionmark.app.dashed").foregroundStyle(.secondary).frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(owner).font(.headline)
                    Text(Set(items.map(\.location)).sorted().joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Bytes.text(items.reduce(0) { $0 + $1.size })).monospacedDigit()
                    Text(Count.items(items.count)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .combine)
        }
    }
}
