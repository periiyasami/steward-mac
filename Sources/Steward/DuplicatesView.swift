import AppKit
import QuickLook
import StewardKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dm = model.duplicates
        content(dm)
            .navigationTitle("Duplicates")
            .navigationSubtitle(model.display(dm.root))
            .toolbar { DuplicatesToolbar(dm: dm) }
    }

    @ViewBuilder
    private func content(_ dm: DuplicatesModel) -> some View {
        if !dm.hasScanned {
            VStack(spacing: Space.lg) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 56))
                    .foregroundStyle(Palette.accentText)
                    .accessibilityHidden(true)
                Text("Duplicates").font(.largeTitle.bold())
                Text("Find files with exactly the same contents in \(model.display(dm.root)). Steward compares the contents, not just the names, and always keeps one copy.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                HStack(spacing: Space.md) {
                    Button("Choose Folder…") { dm.chooseFolder(skipped: model.skipList()) }
                    Button("Find Duplicates") { dm.scan(skipped: model.skipList()) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.extraLarge)
                .padding(.top, Space.sm)
            }
            .padding(Space.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if dm.scanning && dm.groups.isEmpty {
            VStack(spacing: Space.md) {
                ProgressView()
                Text(dm.status ?? "Looking for duplicates…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { dm.stop() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Space.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if dm.groups.isEmpty {
            ContentUnavailableView {
                Label("No Duplicates", systemImage: "doc.on.doc")
            } description: {
                Text("No files over \(Bytes.text(dm.minSize)) share the same contents in \(model.display(dm.root)).")
            } actions: {
                Button("Choose Folder…") { dm.chooseFolder(skipped: model.skipList()) }
            }
        } else {
            DuplicatesList(dm: dm)
                .safeAreaInset(edge: .top) {
                    HStack {
                        Text("\(dm.groups.count) \(dm.groups.count == 1 ? "file has" : "files have") copies, \(Bytes.text(dm.extraBytes)) in extra copies")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let message = dm.message {
                            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
                    .background(.bar)
                }
                .safeAreaInset(edge: .bottom) {
                    ReviewFooter(
                        status: dm.status,
                        selected: dm.tickedFiles.isEmpty ? "Nothing ticked" : "\(Count.items(dm.tickedFiles.count)) ticked, \(Bytes.text(dm.tickedBytes))",
                        canReview: !dm.tickedFiles.isEmpty
                    ) { model.openReviewForCurrentPage() }
                }
        }
    }
}

struct DuplicatesList: View {
    @Bindable var dm: DuplicatesModel
    @Environment(AppModel.self) private var model

    var body: some View {
        let urls = dm.allFiles.map(\.url)
        List(selection: $dm.selection) {
            ForEach(dm.groups) { group in
                Section {
                    ForEach(group.files) { file in
                        DuplicateRow(dm: dm, file: file, isKeep: file.id == group.keep.id).tag(file.id)
                    }
                } header: {
                    HStack {
                        Text(group.keep.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(group.files.count) copies of \(Bytes.text(group.size)) · \(Bytes.text(group.extraBytes)) extra")
                            .monospacedDigit()
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = dm.allFiles.filter { ids.contains($0.id) }.map(\.url)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen) }
            Button("Quick Look") { dm.preview = chosen.first }
            Divider()
            Button("Tick") { dm.ticked.formUnion(ids) }
            Button("Untick") { dm.ticked.subtract(ids) }
            Divider()
            Button("Always Skip") {
                for url in chosen { model.alwaysSkip(url) }
                dm.removed(ids)
            }
        } primaryAction: { ids in
            NSWorkspace.shared.activateFileViewerSelecting(dm.allFiles.filter { ids.contains($0.id) }.map(\.url))
        }
        .quickLookPreview($dm.preview, in: urls)
        .onKeyPress(.space) {
            guard let first = dm.selectedURLs.first else { return .ignored }
            dm.preview = dm.preview == nil ? first : nil
            return .handled
        }
        .onKeyPress(.return) {
            guard !dm.selection.isEmpty else { return .ignored }
            if dm.selection.isSubset(of: dm.ticked) { dm.ticked.subtract(dm.selection) } else { dm.ticked.formUnion(dm.selection) }
            return .handled
        }
    }
}

struct DuplicateRow: View {
    let dm: DuplicatesModel
    let file: DuplicateFile
    let isKeep: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(get: { dm.ticked.contains(file.id) }, set: { _ in dm.toggle(file) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Tick \(file.name) in \(model.display(file.url.deletingLastPathComponent()))")
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(model.display(file.url.deletingLastPathComponent()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(model.display(file.url))
            Spacer(minLength: Space.md)
            if isKeep {
                Text("Suggested to Keep")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accentText)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.accent.opacity(0.14)))
                    .help("Outside Downloads and Desktop, and the oldest copy")
            }
            if let date = file.modified {
                Text(date, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .draggable(file.url)
    }
}

struct DuplicatesToolbar: ToolbarContent {
    @Bindable var dm: DuplicatesModel
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Size", selection: $dm.minSize) {
                ForEach(DuplicateFinder.sizeChoices, id: \.self) { Text("Over \(Bytes.text($0))").tag($0) }
            }
            .help("Compare files over this size; rescan to apply")
            Button("Tick Extra Copies", systemImage: "checklist") { dm.tickExtraCopies() }
                .disabled(dm.groups.isEmpty)
                .help("Tick every copy except the suggested one (⇧⌘E)")
        }
        ToolbarItemGroup {
            Button("Choose Folder…", systemImage: "folder") { dm.chooseFolder(skipped: model.skipList()) }
                .help("Look through another folder")
            if dm.scanning {
                Button("Stop", systemImage: "stop.circle") { dm.stop() }
                    .help("Stop looking and keep what was found (⌘.)")
            } else {
                Button(dm.hasScanned ? "Rescan" : "Find Duplicates", systemImage: "arrow.clockwise") { dm.scan(skipped: model.skipList()) }
                    .help("Look through the folder again")
            }
        }
    }
}
