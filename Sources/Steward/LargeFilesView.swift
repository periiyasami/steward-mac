import AppKit
import QuickLook
import StewardKit
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lf = model.largeFiles
        content(lf)
            .navigationTitle("Large & Old Files")
            .navigationSubtitle(model.display(lf.root))
            .toolbar { LargeFilesToolbar(lf: lf) }
            .task {
                if !lf.hasScanned, !Store.isOverridden { lf.scan(skipped: model.skipList()) }
            }
    }

    @ViewBuilder
    private func content(_ lf: LargeFilesModel) -> some View {
        if lf.scanning && lf.files.isEmpty {
            VStack(spacing: Space.md) {
                ProgressView()
                Text(lf.currentFolder.map { "Looking in \(model.display($0))…" } ?? "Looking for large files…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { lf.stop() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Space.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lf.visible.isEmpty {
            ContentUnavailableView {
                Label("No Large Files", systemImage: "doc.badge.clock")
            } description: {
                Text("No files over \(Bytes.text(lf.threshold)) match these filters in \(model.display(lf.root)).")
            } actions: {
                Button("Choose Folder…") { lf.chooseFolder(skipped: model.skipList()) }
            }
        } else {
            LargeFilesTable(lf: lf)
                .safeAreaInset(edge: .bottom) {
                    ReviewFooter(
                        status: lf.scanning ? lf.currentFolder.map { "Looking in \(model.display($0))…" } : nil,
                        selected: lf.tickedVisible.isEmpty ? "Nothing ticked" : "\(Count.items(lf.tickedVisible.count)) ticked, \(Bytes.text(lf.tickedVisible.reduce(0) { $0 + $1.size }))",
                        canReview: !lf.tickedVisible.isEmpty
                    ) { model.openReviewForCurrentPage() }
                }
        }
    }
}

struct LargeFilesTable: View {
    @Bindable var lf: LargeFilesModel
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = lf.visible
        Table(rows, selection: $lf.selection) {
            TableColumn("") { file in
                Toggle(isOn: Binding(get: { lf.ticked.contains(file.id) }, set: { _ in lf.toggle(file) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Tick \(file.name)")
            }
            .width(20)
            TableColumn("Name") { file in
                Label {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .help(file.name)
                .draggable(file.url)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Folder") { file in
                Text(model.display(file.url.deletingLastPathComponent()))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.display(file.url.deletingLastPathComponent()))
            }
            .width(min: 120, ideal: 200)
            TableColumn("Kind") { file in
                Text(file.kind.rowTitle).foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 88)
            TableColumn("Last Opened") { file in
                if let date = file.lastOpened {
                    Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
            .width(min: 88, ideal: 120)
            TableColumn("Size") { file in
                Text(Bytes.text(file.size)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 88)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let urls = rows.filter { ids.contains($0.id) }.map(\.url)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("Quick Look") { lf.preview = urls.first }
            Divider()
            Button("Tick") { lf.ticked.formUnion(ids) }
            Button("Untick") { lf.ticked.subtract(ids) }
            Divider()
            Button("Always Skip") {
                for url in urls { model.alwaysSkip(url) }
                lf.removed(ids)
            }
        } primaryAction: { ids in
            NSWorkspace.shared.activateFileViewerSelecting(rows.filter { ids.contains($0.id) }.map(\.url))
        }
        .quickLookPreview($lf.preview, in: rows.map(\.url))
        .onKeyPress(.space) {
            guard let first = lf.selectedURLs.first else { return .ignored }
            lf.preview = lf.preview == nil ? first : nil
            return .handled
        }
        .onKeyPress(.return) {
            guard !lf.selection.isEmpty else { return .ignored }
            let allTicked = lf.selection.isSubset(of: lf.ticked)
            if allTicked { lf.ticked.subtract(lf.selection) } else { lf.ticked.formUnion(lf.selection) }
            return .handled
        }
    }
}

struct LargeFilesToolbar: ToolbarContent {
    @Bindable var lf: LargeFilesModel
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Size", selection: $lf.threshold) {
                ForEach(LargeFileFilter.thresholds, id: \.self) { t in
                    Text("Over \(Bytes.text(t))").tag(t)
                }
            }
            .help("Show files over this size")
            Picker("Last Opened", selection: $lf.age) {
                ForEach(FileAge.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("Show only files you haven't opened in a while")
            Picker("Kind", selection: $lf.kind) {
                Text("All Kinds").tag(FileKind?.none)
                Divider()
                ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag(FileKind?.some($0)) }
            }
            .help("Show only one kind of file")
        }
        ToolbarItemGroup {
            Button("Choose Folder…", systemImage: "folder") { lf.chooseFolder(skipped: model.skipList()) }
                .help("Look through another folder")
            if lf.scanning {
                Button("Stop", systemImage: "stop.circle") { lf.stop() }
                    .help("Stop looking and keep what was found (⌘.)")
            } else {
                Button("Rescan", systemImage: "arrow.clockwise") { lf.scan(skipped: model.skipList()) }
                    .help("Look through the folder again")
            }
        }
    }
}
