import AppKit
import StewardKit
import SwiftUI

struct DiskMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let map = model.diskMap
        content(map)
            .navigationTitle("Disk Map")
            .navigationSubtitle(model.display(map.root))
            .toolbar {
                ToolbarItemGroup {
                    Button("Enclosing Folder", systemImage: "chevron.up") { map.up() }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .disabled(!map.canGoUp)
                        .help("Go up one folder (⌘↑)")
                    Button("Choose Folder…", systemImage: "folder") { map.chooseFolder() }
                        .help("Measure another folder")
                    if map.measuring {
                        Button("Stop", systemImage: "stop.circle") { map.stop() }
                            .help("Stop measuring and keep what was measured (⌘.)")
                    } else {
                        Button("Rescan", systemImage: "arrow.clockwise") { map.measure() }
                            .help("Measure the folder again")
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                map.measure(url)
                return true
            }
            .task {
                if !map.hasMeasured, !Store.isOverridden { map.measure() }
            }
    }

    @ViewBuilder
    private func content(_ map: DiskMapModel) -> some View {
        if let current = map.current {
            VStack(spacing: 0) {
                PathBar(map: map)
                Divider()
                HStack(spacing: 0) {
                    if current.children.isEmpty {
                        ContentUnavailableView("Empty Folder", systemImage: "folder",
                                               description: Text("Nothing in this folder takes up space."))
                    } else {
                        TreemapView(map: map, node: current)
                            .padding(Space.sm)
                    }
                    Divider()
                    DiskMapList(map: map, node: current)
                        .frame(width: 280)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ReviewFooter(
                    status: map.measuring ? "Measuring \(model.display(map.root))… \(Bytes.text(map.tree?.size ?? 0)) so far" : nil,
                    selected: map.collected.isEmpty
                        ? "Right-click a block and choose Add to Review."
                        : "\(Count.items(map.collected.count)) to review, \(Bytes.text(map.collectedBytes))",
                    canReview: !map.collected.isEmpty
                ) { model.openReviewForCurrentPage() }
            }
        } else if map.measuring {
            VStack(spacing: Space.md) {
                ProgressView()
                Text("Measuring \(model.display(map.root))…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Disk Map", systemImage: "square.grid.3x3.square")
            } description: {
                Text("See what takes up space, folder by folder. Choose a folder or drop one here.")
            } actions: {
                Button("Measure Home Folder") { map.measure(model.home) }
                    .buttonStyle(.borderedProminent)
                Button("Choose Folder…") { map.chooseFolder() }
            }
        }
    }
}

/// Root to current folder; each level is a button.
struct PathBar: View {
    let map: DiskMapModel
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                ForEach(Array(map.trail.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button {
                        map.go(to: index)
                    } label: {
                        Text(index == 0 ? model.display(node.url) : node.name)
                            .fontWeight(index == map.trail.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.borderless)
                    .help("Go to \(model.display(node.url))")
                }
                Spacer(minLength: Space.md)
                if let node = map.current {
                    Text(Bytes.text(node.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.sm)
        }
    }
}

/// The blocks, drawn on a Canvas. Hover highlights, a click goes into a
/// folder, and the context menu acts on the block under the pointer.
struct TreemapView: View {
    let map: DiskMapModel
    let node: DiskNode
    @State private var size: CGSize = .zero

    var body: some View {
        let kids = node.children
        let blocks = Treemap.layout(kids.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
        Canvas { context, _ in
            for block in blocks {
                let child = kids[block.index]
                let rect = block.rect.insetBy(dx: 1.5, dy: 1.5)
                guard rect.width > 1, rect.height > 1 else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: min(6, rect.width / 4, rect.height / 4))
                let color = DiskColors.color(for: child, index: block.index)
                let lit = map.highlighted == child.id
                context.fill(shape, with: .color(color.opacity(lit ? 0.5 : 0.24)))
                context.stroke(shape, with: .color(color.opacity(map.isCollected(child) ? 1 : 0.55)),
                               lineWidth: map.isCollected(child) ? 3 : 1)
                let showsLabel = rect.width > 72 && rect.height > 36
                // One level of children inside a folder, below its label.
                if child.isDirectory, !child.children.isEmpty, rect.width > 96, rect.height > 88 {
                    let inner = CGRect(x: rect.minX + 4, y: rect.minY + 40, width: rect.width - 8, height: rect.height - 44)
                    let subs = Treemap.layout(child.children.map { Double($0.size) }, in: inner)
                    for sub in subs {
                        let r = sub.rect.insetBy(dx: 1, dy: 1)
                        guard r.width > 2, r.height > 2 else { continue }
                        let grandchild = child.children[sub.index]
                        let p = Path(roundedRect: r, cornerRadius: min(4, r.width / 4, r.height / 4))
                        let c = grandchild.isDirectory ? color : DiskColors.color(for: grandchild, index: sub.index)
                        context.fill(p, with: .color(c.opacity(0.22)))
                        context.stroke(p, with: .color(c.opacity(0.35)), lineWidth: 0.5) // grid: ok hairline stroke, not spacing
                        if r.width > 90, r.height > 30 {
                            var clipped = context
                            clipped.clip(to: p)
                            clipped.draw(Text(grandchild.name).font(.caption).foregroundStyle(.secondary),
                                         in: r.insetBy(dx: 6, dy: 4))
                        }
                    }
                }
                if showsLabel {
                    var inner = context
                    inner.clip(to: shape)
                    let sizeText = Text(Bytes.text(child.size)).font(.caption).foregroundStyle(.secondary)
                    let label = Text("\(Text(child.name).font(.callout.weight(.medium)))\n\(sizeText)")
                    inner.draw(label, in: rect.insetBy(dx: 8, dy: 6))
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): map.highlighted = hit(point, blocks: blocks, kids: kids)?.id
            case .ended: map.highlighted = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { tap in
            if let child = hit(tap.location, blocks: blocks, kids: kids) { map.open(child) }
        })
        .contextMenu {
            if let child = kids.first(where: { $0.id == map.highlighted }) {
                DiskNodeMenu(map: map, node: child)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Disk Map of \(node.name)")
        .accessibilityValue("\(Count.items(kids.count)), \(Bytes.text(node.size)). The list beside it has the same items.")
    }

    private func hit(_ point: CGPoint, blocks: [Treemap.Block], kids: [DiskNode]) -> DiskNode? {
        blocks.first { $0.rect.contains(point) }.map { kids[$0.index] }
    }
}

struct DiskNodeMenu: View {
    let map: DiskMapModel
    let node: DiskNode

    var body: some View {
        if node.isDirectory && !node.isOther {
            Button("Open") { map.open(node) }
        }
        if !node.isOther {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Divider()
            if map.isCollected(node) {
                Button("Remove from Review") { map.toggleCollected(node) }
            } else {
                Button("Add to Review") { map.toggleCollected(node) }
                    .disabled(!map.canCollect(node))
            }
        }
    }
}

/// The same items as the map, as a list: readable by VoiceOver and the keyboard.
struct DiskMapList: View {
    let map: DiskMapModel
    let node: DiskNode

    var body: some View {
        List(node.children, selection: Binding(get: { map.highlighted }, set: { map.highlighted = $0 })) { child in
            HStack(spacing: Space.sm) {
                Circle().fill(DiskColors.color(for: child, index: node.children.firstIndex(of: child) ?? 0)).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(child.name).lineLimit(1).truncationMode(.middle)
                if map.isCollected(child) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accentText)
                        .help("Added to Review")
                        .accessibilityLabel("Added to Review")
                }
                Spacer(minLength: Space.sm)
                Text(Bytes.text(child.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .tag(child.id)
            .draggable(child.url)
            .contextMenu { DiskNodeMenu(map: map, node: child) }
        }
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
            if let child = node.children.first(where: { ids.contains($0.id) }) { map.open(child) }
        }
    }
}

enum DiskColors {
    /// Folders take turns through these, so neighbours read apart.
    static let folders: [Color] = [.blue, .teal, .purple, .mint, .cyan, .indigo, .brown]

    static func color(for node: DiskNode, index: Int) -> Color {
        if node.isOther { return .secondary }
        if node.isDirectory { return folders[index % folders.count] }
        switch node.kind {
        case .video: return .indigo
        case .archive: return .orange
        case .diskImage: return .pink
        case .other: return .gray
        }
    }
}
