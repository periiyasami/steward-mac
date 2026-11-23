import AppKit
import SwiftData
import SwiftUI

// Steward
//   Steward                      the app
//   APP_STORE=<file> Steward     use another database (tests, experiments)
//   APP_SNAPSHOT=<dir> Steward   save a PNG of every sidebar page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 Steward           fill an empty /tmp store with sample cleans and skipped items (tools/snap.sh)
//   APP_HOME=<dir> Steward       scan and clean a fixture home folder instead of the real one
//   APP_TRASH=<dir> Steward      move items to this folder instead of the Trash (self-test)
//                                The holding area always sits next to the database ("<store> Holding").
//   Steward --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Steward      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Steward           draw the 8 pt grid and the layout probes over the window

@main
struct StewardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(container: Store.makeContainer())

    var body: some Scene {
        Window("Steward", id: "main") {
            ContentView()
                .environment(model)
                .task { StatusBarController.shared.attach(model) }
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 760, minHeight: 480)
        }
        .modelContainer(model.container)
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Divider()
                ForEach(Module.allCases) { module in
                    Button(module.title) { model.show(module) }
                        .keyboardShortcut(KeyEquivalent(module.shortcut))
                }
                Divider()
                Button("Next Page") { model.movePage(by: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Page") { model.movePage(by: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("History") { model.sidebar = .history }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
            }
            CommandMenu("Storage") {
                Button("Scan") { model.sidebar = .scan; model.startScan() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isScanning || model.showsAccessPage)
                Button("Stop") { model.stopCurrent() }
                    .keyboardShortcut(".")
                    .disabled(!model.canStop)
                Divider()
                Button("Review…") { model.openReviewForCurrentPage() }
                    .keyboardShortcut(.return)
                    .disabled(!model.canOpenReview)
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.selectedURLs) }
                    .keyboardShortcut("r")
                    .disabled(model.selectedURLs.isEmpty)
                Button("Quick Look") { model.quickLookSelection() }
                    .keyboardShortcut("y")
                    .disabled(!(model.sidebar == .largeFiles || model.sidebar == .duplicates) || model.selectedURLs.isEmpty)
                Divider()
                Button("Tick Extra Copies") { model.duplicates.tickExtraCopies() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.sidebar != .duplicates || model.duplicates.groups.isEmpty)
                Divider()
                Button("Put Back") { model.putBackSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.canPutBack)
                Button("Delete Now…") { model.holdingModel.confirming = .deleteSelected }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(!model.canDeleteHeld)
                Button("Empty Holding Area…") { model.sidebar = .holding; model.holdingModel.confirming = .emptyHolding }
                    .keyboardShortcut(.delete, modifiers: [.command, .option, .shift])
                Button("Empty Trash…") { model.sidebar = .holding; model.holdingModel.confirming = .emptyTrash }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .modelContainer(model.container)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// With the menu bar item on, Steward keeps running after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Prefs.menuBar
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where the data lives: ~/Library/Application Support/Steward/Steward.store
enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "Steward", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Steward.store")
    }

    /// Steward's holding area, next to the database: "Steward Holding".
    static var holdingURL: URL {
        url.deletingLastPathComponent().appending(path: url.deletingPathExtension().lastPathComponent + " Holding", directoryHint: .isDirectory)
    }

    static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: CleanRecord.self, CleanEntry.self, SkipRule.self, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
        }
    }
}
