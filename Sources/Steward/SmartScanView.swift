import AppKit
import StewardKit
import SwiftUI

struct SmartScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .navigationTitle("Smart Scan")
            .toolbar {
                ToolbarItem {
                    if model.isScanning {
                        Button("Stop", systemImage: "stop.circle") { model.stopScan() }
                            .help("Stop the scan and keep what was found (⌘.)")
                    } else if model.phase != .idle {
                        Button("Rescan", systemImage: "arrow.clockwise") { model.startScan() }
                            .help("Scan again for items to clean (⇧⌘S)")
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.showsAccessPage {
            AccessView()
        } else {
            switch model.phase {
            case .idle: IdleScanView()
            case .running(let current, let count, let bytes): RunningScanView(current: current, count: count, bytes: bytes)
            case .results: ScanResultsView()
            case .done: CleanDoneView()
            }
        }
    }
}

// MARK: - Full Disk Access

struct AccessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            Text("Let Steward See Your Whole Home Folder")
                .font(.title2.bold())
            Text("Steward needs Full Disk Access to look inside app data folders. It only reads, and nothing leaves this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("In System Settings, turn on Steward, then reopen Steward.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.md) {
                Button("Continue Without Full Disk Access") { model.accessSkipped = true }
                Button("Open System Settings") { SystemSettings.openFullDiskAccess() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, Space.sm)
        }
        .padding(Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Idle

struct IdleScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            Text("Smart Scan")
                .font(.largeTitle.bold())
            Text("Find caches, logs, and build files that apps can rebuild. Nothing moves until you review it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Scan") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Space.sm)
            if let available = model.available {
                Text("\(Bytes.text(available)) available")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.hasFullDiskAccess {
                HStack(spacing: Space.xs) {
                    Text("Some folders need Full Disk Access.")
                    Button("Open System Settings") { SystemSettings.openFullDiskAccess() }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Running

struct RunningScanView: View {
    let current: ScanCategory?
    let count: Int
    let bytes: Int64
    @Environment(AppModel.self) private var model

    private var progress: Double {
        guard let current, let index = ScanCategory.allCases.firstIndex(of: current) else { return 0 }
        return Double(index) / Double(ScanCategory.allCases.count)
    }

    var body: some View {
        VStack(spacing: Space.lg) {
            ProgressView(value: progress)
                .frame(width: 320)
            Text(current.map { "Scanning \($0.title)…" } ?? "Starting…")
                .font(.title3)
                .accessibilityAddTraits(.updatesFrequently)
            Text("\(Count.items(count)), \(Bytes.text(bytes)) so far")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Stop") { model.stopScan() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .help("Stop the scan and keep what was found (⌘.)")
        }
        .padding(Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

struct ScanResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.items.isEmpty && model.notScanned.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Clean Right Now", systemImage: "checkmark.circle")
            } description: {
                Text("Steward found no caches, logs, or build files to move to the Trash.")
            } actions: {
                Button("Rescan") { model.startScan() }
            }
        } else {
            @Bindable var model = model
            List(selection: $model.scanSelection) {
                ForEach(model.categories, id: \.self) { category in
                    CategoryGroup(category: category)
                }
                if !model.notScanned.isEmpty {
                    Section("Not Scanned") {
                        ForEach(model.notScanned, id: \.self) { url in
                            NotScannedRow(url: url)
                        }
                    }
                }
            }
            .onKeyPress(.return) { model.toggleScanSelection(); return .handled }
            .onKeyPress(.space) { model.toggleScanSelection(); return .handled }
            .safeAreaInset(edge: .top) {
                if let date = model.scannedAt {
                    HStack {
                        Text("Scanned \(date, format: .relative(presentation: .named))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Select rows, then press Return to tick or untick them.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
                    .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom) { ReviewBar() }
        }
    }
}

struct CategoryGroup: View {
    let category: ScanCategory
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let items = model.items(in: category)
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(items) { ScanItemRow(item: $0).tag($0.id) }
        } label: {
            HStack(spacing: Space.md) {
                Toggle(sources: items.map { binding(for: $0) }, isOn: \.self) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(category.title)
                Image(systemName: category.symbol)
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.headline)
                    Text(category.reason).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                if category.isRecommended { RecommendedBadge() }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Bytes.text(total)).monospacedDigit()
                    Text(Count.items(items.count)).font(.callout).foregroundStyle(.secondary)
                }
                .frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .combine)
        }
        .tag("cat:" + category.rawValue)
    }

    private func binding(for item: ScanItem) -> Binding<Bool> {
        Binding(get: { model.ticked.contains(item.id) },
                set: { on in if on { model.ticked.insert(item.id) } else { model.ticked.remove(item.id) } })
    }
}

struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.accentText)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.accent.opacity(0.14)))
            .help("Apps rebuild these on their own, so Steward ticks them for you")
    }
}

struct ScanItemRow: View {
    let item: ScanItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(get: { model.ticked.contains(item.id) }, set: { _ in model.toggle(item) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(item.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(model.display(item.url))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(model.display(item.url))
            Spacer(minLength: Space.md)
            if let owner = model.openOwners[item.id] {
                Label("\(owner) is open", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Quit \(owner) before moving its cache. Steward leaves it unticked.")
            }
            if let date = item.lastOpened {
                Text(date, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(Bytes.text(item.size))
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
        }
        .contextMenu { ItemMenu(item: item) }
        .draggable(item.url)
    }
}

struct ItemMenu: View {
    let item: ScanItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Always Skip") { model.alwaysSkip(item.url) }
    }
}

struct NotScannedRow: View {
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(model.display(url)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !model.hasFullDiskAccess {
                Button("Open System Settings") { SystemSettings.openFullDiskAccess() }
                    .buttonStyle(.link)
                    .help("Give Steward Full Disk Access so it can read this folder")
            }
        }
    }
}

struct ReviewBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ReviewFooter(selected: "\(Bytes.text(model.tickedBytes)) selected",
                     canReview: !model.tickedItems.isEmpty) { model.openReview() }
    }
}

// MARK: - Done

struct CleanDoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let summary = model.lastClean ?? CleanSummary(source: .smartScan, moved: [], failed: [])
        VStack(spacing: Space.lg) {
            Image(systemName: summary.undone ? "arrow.uturn.backward.circle" : "checkmark.circle")
                .font(.system(size: 56))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            Text(title(summary))
                .font(.title2.bold())
            Text(detail(summary))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if !summary.failed.isEmpty {
                DisclosureGroup("\(Count.items(summary.failed.count)) couldn't move") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(summary.failed, id: \.self) { failed in
                            HStack {
                                Text(model.display(failed.url)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(failed.message).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, Space.xs)
                }
                .frame(maxWidth: 440)
            }
            HStack(spacing: Space.md) {
                if model.canUndoLastClean {
                    Button("Undo \(model.destination.action)") {
                        undoManager?.removeAllActions(withTarget: model)
                        model.undoLastClean()
                    }
                    .help("Put these items back where they were (⌘Z)")
                    Button("Free the Space…") { model.sidebar = .holding }
                        .help(model.destination == .holding
                              ? "Open Trash & Holding to delete held items now"
                              : "Open Trash & Holding to empty the Trash")
                }
                Button("Scan Again") { model.startScan() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, Space.sm)
        }
        .padding(Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func title(_ s: CleanSummary) -> String {
        if s.undone { return "Put \(Count.items(s.moved.count, capitalized: true)) Back" }
        let place = model.destination == .holding ? "the Holding Area" : "the Trash"
        if s.moved.isEmpty { return "Nothing Moved to \(place)" }
        return "Moved \(Count.items(s.moved.count, capitalized: true)) to \(place)"
    }

    private func detail(_ s: CleanSummary) -> String {
        if s.undone { return "Every item is back where it was." }
        if s.moved.isEmpty { return "None of the items could move. See the list below." }
        if model.destination == .holding {
            return "\(Bytes.text(s.bytes)) moved. Steward deletes it for good in \(Prefs.holdingDays) days; until then you can put it back."
        }
        return "\(Bytes.text(s.bytes)) moved. The space comes back when you empty the Trash; until then you can put the items back."
    }
}
