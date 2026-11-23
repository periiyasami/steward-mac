import StewardKit
import SwiftUI

/// Every item that will move to the Trash, before anything moves. Opened
/// by any page with a ReviewSession; unticking here leaves the page alone.
struct ReviewSheet: View {
    let session: ReviewSession
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(session.title ?? "Review \(Count.items(session.rows.count, capitalized: true))")
                    .font(.title2.bold())
                Text(model.destination.promise(days: Prefs.holdingDays))
                    .foregroundStyle(.secondary)
            }
            .padding(Space.margin)

            List(session.rows) { row in
                ReviewRow(row: row, session: session)
            }
            .listStyle(.inset)

            HStack(spacing: Space.md) {
                if model.cleaning {
                    ProgressView().controlSize(.small)
                    Text("Moving to \(model.destination.place)…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.review = nil }
                    .keyboardShortcut(.cancelAction)
                Button("\(model.destination.action) (\(Bytes.text(session.tickedBytes)))") {
                    model.moveToTrash(session, undoManager: undoManager)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.ticked.isEmpty || model.cleaning)
            }
            .padding(Space.margin)
        }
        .frame(width: 640, height: 520)
        .noInitialFocus()
    }
}

struct ReviewRow: View {
    let row: Candidate
    let session: ReviewSession
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(get: { session.ticked.contains(row.id) }, set: { _ in session.toggle(row) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(row.url.lastPathComponent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.display(row.url))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(model.display(row.url))
            Spacer(minLength: Space.md)
            Text(Bytes.text(row.size))
                .monospacedDigit()
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
        }
    }
}

/// The bar under a page's list: what is ticked, and Review….
struct ReviewFooter: View {
    var status: String? = nil
    let selected: String
    let canReview: Bool
    let review: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            if let status {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text(selected).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review…", action: review)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canReview)
                .help(canReview ? "See every item before anything moves (⌘↩)" : "Tick at least one item to review")
        }
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.md)
        .background(.bar)
    }
}
