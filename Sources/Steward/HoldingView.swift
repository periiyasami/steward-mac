import AppKit
import SwiftData
import StewardKit
import SwiftUI

/// Trash & Holding: what Steward cleaned that can still come back, and the
/// buttons that free the space for good.
struct HoldingView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \CleanEntry.size, order: .reverse) private var entries: [CleanEntry]

    /// Items Steward moved to the system Trash that are still there.
    private var inTrash: [CleanEntry] {
        entries.filter { !model.holding.contains(URL(fileURLWithPath: $0.trashPath)) && $0.isStillInTrash }
    }

    var body: some View {
        @Bindable var hm = model.holdingModel
        let trashRows = inTrash
        Group {
            if hm.items.isEmpty && trashRows.isEmpty && !hm.loading {
                ContentUnavailableView {
                    Label("Nothing Waiting", systemImage: "trash")
                } description: {
                    Text(model.destination == .holding
                         ? "Items you clean wait here for \(Prefs.holdingDays) days, so you can put them back."
                         : "Items Steward moves to the Trash show here until you empty it.")
                } actions: {
                    Button("Empty Trash…") { hm.confirming = .emptyTrash }
                }
            } else {
                List(selection: $hm.selection) {
                    Section {
                        if hm.items.isEmpty {
                            Text(hm.loading ? "Loading…" : "Nothing in the holding area.").foregroundStyle(.secondary)
                        }
                        ForEach(hm.items) { HeldRow(item: $0).tag($0.id) }
                    } header: {
                        SectionTotal(title: "Holding Area", bytes: hm.totalBytes)
                    } footer: {
                        Text("Steward deletes held items for good after \(Prefs.holdingDays) days. Change this in Settings > Storage.")
                            .foregroundStyle(.secondary)
                    }
                    if !trashRows.isEmpty {
                        Section {
                            ForEach(trashRows) { TrashEntryRow(entry: $0).tag(HoldingModel.trashPrefix + $0.trashPath) }
                        } header: {
                            SectionTotal(title: "Moved to the Trash by Steward", bytes: trashRows.reduce(0) { $0 + $1.size })
                        } footer: {
                            Text("The space comes back when you empty the Trash.").foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Put Back") { hm.selection = ids; model.putBackSelection() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls(for: ids, trash: trashRows)) }
                    if hm.items.contains(where: { ids.contains($0.id) }) {
                        Divider()
                        Button("Delete Now…") { hm.selection = ids; hm.confirming = .deleteSelected }
                    }
                } primaryAction: { ids in
                    NSWorkspace.shared.activateFileViewerSelecting(urls(for: ids, trash: trashRows))
                }
            }
        }
        .safeAreaInset(edge: .bottom) { HoldingFooter() }
        .navigationTitle("Trash & Holding")
        .toolbar { HoldingToolbar() }
        .confirmationDialog(title(hm.confirming), isPresented: Binding(get: { hm.confirming != nil }, set: { if !$0 { hm.confirming = nil } }),
                            presenting: hm.confirming) { confirm in
            switch confirm {
            case .deleteSelected:
                Button("Delete \(Count.items(hm.selectedItems.count, capitalized: true))", role: .destructive) { model.deleteHeld(hm.selectedItems) }
            case .emptyHolding:
                Button("Empty Holding Area", role: .destructive) { model.deleteHeld(hm.items) }
            case .emptyTrash:
                Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            }
        } message: { confirm in
            switch confirm {
            case .deleteSelected, .emptyHolding: Text("These items are deleted for good. You can't put them back.")
            case .emptyTrash: Text("Everything in the Trash is deleted for good, not only what Steward moved there. macOS may ask to let Steward control Finder.")
            }
        }
        .task { if !hm.hasLoaded, !Store.isOverridden { hm.load() } }
    }

    private func title(_ confirm: HoldingModel.Confirm?) -> String {
        switch confirm {
        case .deleteSelected: "Delete the selected items now?"
        case .emptyHolding: "Empty the holding area?"
        case .emptyTrash: "Empty the Trash?"
        case nil: ""
        }
    }

    private func urls(for ids: Set<String>, trash: [CleanEntry]) -> [URL] {
        model.holdingModel.items.filter { ids.contains($0.id) }.map(\.location)
            + trash.filter { ids.contains(HoldingModel.trashPrefix + $0.trashPath) }.map { URL(fileURLWithPath: $0.trashPath) }
    }
}

struct SectionTotal: View {
    let title: String
    let bytes: Int64

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(Bytes.text(bytes)).monospacedDigit()
        }
    }
}

struct HeldRow: View {
    let item: HeldItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.location.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.original.map { "From \(model.display($0.deletingLastPathComponent()))" } ?? "Origin unknown")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(item.original.map { model.display($0) } ?? item.name)
            Spacer(minLength: Space.md)
            Text(expiry)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(Bytes.text(item.size))
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var expiry: String {
        let date = item.expires(afterDays: Prefs.holdingDays)
        if date <= .now { return "Deleted soon" }
        return "Deleted \(date.formatted(.relative(presentation: .named)))"
    }
}

struct TrashEntryRow: View {
    let entry: CleanEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.trashPath))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: entry.originalPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("From \(model.display(URL(fileURLWithPath: entry.originalPath).deletingLastPathComponent()))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(model.display(entry.originalPath))
            Spacer(minLength: Space.md)
            Text(entry.categoryTitle).font(.callout).foregroundStyle(.secondary)
            Text(Bytes.text(entry.size))
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HoldingFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hm = model.holdingModel
        HStack(spacing: Space.md) {
            Text(hm.message ?? (model.destination == .holding
                 ? "Cleaned items wait here for \(Prefs.holdingDays) days."
                 : "Cleaned items go to the Trash. Empty it to free the space."))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Put Back") { model.putBackSelection() }
                .disabled(!model.canPutBack)
                .help("Put the selected items back where they were (⌘⌫)")
            Button("Delete Now…") { hm.confirming = .deleteSelected }
                .disabled(!model.canDeleteHeld)
                .help("Delete the selected held items for good (⌥⌘⌫)")
        }
        .controlSize(.large)
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.md)
        .background(.bar)
    }
}

struct HoldingToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        let hm = model.holdingModel
        ToolbarItemGroup {
            Button("Empty Holding Area…", systemImage: "tray") { hm.confirming = .emptyHolding }
                .disabled(hm.items.isEmpty)
                .help("Delete everything in the holding area for good (⌥⇧⌘⌫)")
            Button("Empty Trash…", systemImage: "trash") { hm.confirming = .emptyTrash }
                .help("Empty the system Trash (⇧⌘⌫)")
            Button("Refresh", systemImage: "arrow.clockwise") { hm.load() }
                .help("Look in the holding area again")
        }
    }
}
