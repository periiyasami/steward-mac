import AppKit
import SwiftData
import SwiftUI

/// Past cleans, newest first.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \CleanRecord.date, order: .reverse) private var records: [CleanRecord]

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("No Cleans Yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Items you clean appear here.")
                } actions: {
                    Button("Go to Smart Scan") { model.sidebar = .scan }
                }
            } else {
                List(records) { record in
                    HistoryGroup(record: record)
                }
            }
        }
        .navigationTitle("History")
    }
}

struct HistoryGroup: View {
    let record: CleanRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        DisclosureGroup {
            ForEach(record.entries.sorted { $0.size > $1.size }) { entry in
                HStack(spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.display(entry.originalPath)).lineLimit(1).truncationMode(.middle)
                        Text(entry.categoryTitle).font(.callout).foregroundStyle(.secondary)
                    }
                    .help(model.display(entry.originalPath))
                    Spacer(minLength: Space.md)
                    Text(Bytes.text(entry.size)).monospacedDigit()
                    let held = model.holding.contains(URL(fileURLWithPath: entry.trashPath))
                    if entry.isStillInTrash {
                        Button(held ? "Show in Holding" : "Show in Trash") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.trashPath)])
                        }
                        .help(held ? "Reveal this item in the holding area in Finder" : "Reveal this item in the Trash in Finder")
                    } else {
                        Text(held ? "Deleted" : "Emptied")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 100)
                            .help(held ? "The holding area deleted this item" : "This item is no longer in the Trash")
                    }
                }
            }
        } label: {
            HStack {
                Text(record.date, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                    .font(.headline)
                Spacer()
                Text("\(Count.items(record.entries.count)) · \(Bytes.text(record.bytes))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .combine)
        }
    }
}
