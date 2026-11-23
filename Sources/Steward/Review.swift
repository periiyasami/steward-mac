import Foundation
import Observation
import StewardKit

/// The page that sent items to Review. Each page updates its own list after a clean.
enum CleanSource: String {
    case smartScan, largeFiles, diskMap, duplicates, uninstaller, leftovers, loginItems, browserData, recentItems
}

/// Where Move to Trash sends things (Settings > Storage).
enum CleanDestination: String, CaseIterable {
    /// The system Trash. Space comes back when the Trash is emptied.
    case trash
    /// Steward's holding area. Steward deletes items for good after a few days.
    case holding

    static let holdingChoices = [1, 3, 7, 14, 30]

    var title: String {
        switch self {
        case .trash: "The Trash"
        case .holding: "Steward's Holding Area"
        }
    }

    /// The button and menu name: "Move to Trash".
    var action: String {
        switch self {
        case .trash: "Move to Trash"
        case .holding: "Move to Holding Area"
        }
    }

    /// "the Trash", for sentences.
    var place: String {
        switch self {
        case .trash: "the Trash"
        case .holding: "the holding area"
        }
    }

    /// One line for the Review sheet.
    func promise(days: Int) -> String {
        switch self {
        case .trash: "These items will move to the Trash. You can put them back until you empty the Trash."
        case .holding: "These items will move to the holding area. You can put them back for \(days) \(days == 1 ? "day" : "days"), then Steward deletes them for good."
        }
    }
}

/// One item in the Review sheet, from any page.
struct Candidate: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let size: Int64
    /// Why it was chosen, shown under the path.
    let reason: String
    /// The group it belongs to, saved in History ("App Caches", "Large File").
    let group: String
    /// Ticked when the sheet opens.
    var ticked = true
    /// An app bundle in /Applications, the one thing outside the home folder Steward may move.
    var isAppBundle = false
}

/// What the Review sheet shows. Unticking here does not change the page behind it.
@Observable
final class ReviewSession: Identifiable {
    let id = UUID()
    let source: CleanSource
    /// A title for the sheet, like "Uninstall Slack". nil gives "Review 12 Items".
    let title: String?
    let rows: [Candidate]
    var ticked: Set<String>

    init(source: CleanSource, rows: [Candidate], title: String? = nil) {
        self.source = source
        self.title = title
        self.rows = rows
        self.ticked = Set(rows.filter(\.ticked).map(\.id))
    }

    var tickedRows: [Candidate] { rows.filter { ticked.contains($0.id) } }
    var tickedBytes: Int64 { tickedRows.reduce(0) { $0 + $1.size } }

    func toggle(_ row: Candidate) {
        if ticked.contains(row.id) { ticked.remove(row.id) } else { ticked.insert(row.id) }
    }
}

/// The last clean's result.
struct CleanSummary {
    let source: CleanSource
    var moved: [MovedItem]
    var failed: [FailedItem]
    /// The candidates that moved, so a page can show them again after Undo.
    var candidates: [Candidate] = []
    var undone = false
    var bytes: Int64 { moved.reduce(0) { $0 + $1.size } }
}
