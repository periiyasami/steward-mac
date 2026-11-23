import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            page(model.sidebar ?? .overview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { PageTabs() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { ModuleBar() }
            ToolbarItem(placement: .navigation) {
                Button("History", systemImage: "clock.arrow.circlepath") { model.sidebar = .history }
                    .help("Past cleans (⇧⌘Y)")
            }
        }
        .sheet(item: $model.review) { session in
            ReviewSheet(session: session)
                .environment(model)
                .themed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !Store.isOverridden else { return }
            model.refreshAccess()
            model.refreshAvailable()
            model.purgeHolding()
        }
        .task {
            let env = ProcessInfo.processInfo.environment
            if (env["APP_SNAPSHOT"] ?? "").isEmpty, !SelfTest.requested, !CommandLine.arguments.contains("--probe") { model.restoreLastScan() }
            SeedData.insertIfRequested(into: model)
            SelfTest.runIfRequested(model: model)
            SelfTest.probeIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }

    @ViewBuilder
    private func page(_ page: SidebarItem) -> some View {
        switch page {
        case .scan: SmartScanView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .holding: HoldingView()
        case .diskMap: DiskMapView()
        case .uninstaller: UninstallerView()
        case .loginItems: LoginItemsView()
        case .unusedApps: UnusedAppsView()
        case .permissions: PermissionsView()
        case .updates: UpdatesView()
        case .background: BackgroundView()
        case .browserData: BrowserDataView()
        case .recentItems: RecentItemsView()
        case .overview: OverviewView()
        case .battery: BatteryView()
        case .history: HistoryView()
        }
    }
}

/// The modules, as a pill bar in the title bar. The selected pill slides between modules.
struct ModuleBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(Module.allCases) { module in
                let selected = model.currentModule == module
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { model.show(module) }
                } label: {
                    Label(module.shortTitle, systemImage: module.symbol)
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.onAccent : .primary)
                        .padding(.horizontal, Space.md)
                        .frame(height: 28)
                        .background {
                            if selected {
                                Capsule().fill(Palette.accent).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(module.title) (⌘\(String(module.shortcut)))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Space.xs)
    }
}

/// The current module's pages as tabs under the title bar, with free space on the right.
struct PageTabs: View {
    @Environment(AppModel.self) private var model
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xl) {
            if let module = model.currentModule {
                ForEach(module.pages) { page in
                    let selected = model.sidebar == page
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { model.sidebar = page }
                    } label: {
                        VStack(spacing: Space.xs) {
                            Label(page.title, systemImage: page.symbol)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Palette.accentText : .secondary)
                            Capsule()
                                .fill(selected ? Palette.accent : .clear)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: selected ? "line" : page.rawValue, in: underline)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            } else {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.accentText)
                    .padding(.bottom, Space.xs + 2)
            }
            Spacer()
            if let available = model.available {
                Label("\(Bytes.text(available)) available", systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Space available on the disk that holds your home folder")
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.md)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
