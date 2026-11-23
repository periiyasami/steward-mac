import AppKit
import Foundation
import Observation
import StewardKit

/// State for the Trash & Holding page: what waits in the holding area.
@Observable
final class HoldingModel {
    let area: HoldingArea
    var items: [HeldItem] = []
    var loading = false
    var hasLoaded = false
    var selection: Set<String> = []
    /// The result of the last Put Back, Delete, or Empty Trash.
    var message: String?

    /// A confirmation the page is showing, opened by a button or a menu item.
    enum Confirm: Identifiable {
        case deleteSelected, emptyHolding, emptyTrash
        var id: Self { self }
    }
    var confirming: Confirm?

    /// Selection ids for Trash rows, which come from History: "trash:<path in the Trash>".
    static let trashPrefix = "trash:"

    init(area: HoldingArea) { self.area = area }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedItems: [HeldItem] { items.filter { selection.contains($0.id) } }
    var selectedURLs: [URL] { selectedItems.map(\.location) }

    func load() {
        loading = true
        hasLoaded = true
        let area = area
        Task {
            let found = await Task.detached { area.items() }.value
            items = found
            selection = selection.intersection(found.map(\.id))
            loading = false
        }
    }

    func loadSample(home: URL) {
        let base = area.folder
        func held(_ path: String, _ size: Int64, daysAgo: Double) -> HeldItem {
            let batch = base.appending(path: UUID().uuidString)
            let original = home.appending(path: path)
            return HeldItem(batch: batch, location: batch.appending(path: original.lastPathComponent), original: original,
                            heldAt: Date.now.addingTimeInterval(-daysAgo * 86_400), size: size)
        }
        items = [held("Library/Caches/com.spotify.client", 1_240_000_000, daysAgo: 6),
                 held("Library/Developer/Xcode/DerivedData/Steward-abc", 3_800_000_000, daysAgo: 2),
                 held("Downloads/Xcode_16.2.xip", 7_210_000_000, daysAgo: 1),
                 held("Library/Logs/DiagnosticReports", 84_000_000, daysAgo: 0.2)]
        loading = false
        hasLoaded = true
    }
}
