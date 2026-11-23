import AppKit
import StewardKit
import SwiftUI

struct LoginItemsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var li = model.loginItems
        Group {
            if li.loading && li.rows.isEmpty {
                ProgressView("Looking for login items…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $li.selection) {
                    if let message = li.message {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Section {
                        if li.userRows.isEmpty {
                            Text("No background agents in your Library.").foregroundStyle(.secondary)
                        }
                        ForEach(li.userRows) { row in
                            LoginItemRow(li: li, row: row).tag(row.id)
                        }
                    } header: {
                        Text("Your Background Agents")
                    } footer: {
                        Text("Turning one off stops it from starting at login. You can turn it back on at any time.")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        HStack(spacing: Space.md) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.title2).foregroundStyle(Palette.accentText).frame(width: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apps That Open at Login")
                                Text("macOS manages these. Steward can't see or change them.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Manage in System Settings") { LoginItemsModel.openLoginItemsSettings() }
                                .help("Open General > Login Items & Extensions in System Settings")
                        }
                        .padding(.vertical, Space.xs)
                    } header: {
                        Text("Managed by macOS")
                    }
                    if !li.systemRows.isEmpty {
                        Section {
                            ForEach(li.systemRows) { row in
                                LoginItemRow(li: li, row: row).tag(row.id)
                            }
                        } header: {
                            Text("For All Users")
                        } footer: {
                            Text("These start for everyone on this Mac. Steward lists them but can't change them.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Login Items")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") { li.load() }
                    .help("Look for login items again")
            }
        }
        .task {
            if !li.hasLoaded, !Store.isOverridden { li.load() }
        }
    }
}

struct LoginItemRow: View {
    let li: LoginItemsModel
    let row: LoginItemsModel.Row
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            if let owner = row.owner {
                AppIcon(url: owner.url, size: 32)
            } else {
                Image(systemName: "gearshape.2").font(.title2).foregroundStyle(.secondary).frame(width: 32)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(row.name).lineLimit(1)
                    Text(row.item.scope.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs)
                        .background(Capsule().strokeBorder(.separator))
                }
                Text(row.owner == nil ? "No matching app found" : row.item.label)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(row.item.plist.path)
            }
            Spacer(minLength: Space.md)
            if row.item.isEditable {
                Toggle(isOn: Binding(get: { row.isOn }, set: { li.setOn(row, $0) })) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Start \(row.name) at login")
                    .help(row.isOn ? "Stop this from starting at login" : "Start this at login again")
            } else {
                Text(row.isOn ? "On" : "Off").foregroundStyle(.secondary)
                    .help("Steward can't change items for all users")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.item.plist]) }
            if row.item.isEditable {
                Divider()
                Button("Move to Trash…") { model.review = li.trashSession(row) }
            }
        }
    }
}
