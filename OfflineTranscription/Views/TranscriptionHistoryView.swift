import SwiftUI
import SwiftData

struct TranscriptionHistoryView: View {
    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse)
    private var records: [TranscriptionRecord]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Transcriptions Yet",
                    systemImage: "doc.text",
                    description: Text("Your saved transcriptions will appear here.")
                )
                .accessibilityIdentifier("history_empty_state")
            } else {
                ForEach(records) { record in
                    NavigationLink(value: record) {
                        HistoryRowView(record: record)
                    }
                    .accessibilityIdentifier("history_row")
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let record = records[index]
                        SessionFileManager.deleteSession(for: record.id)
                        modelContext.delete(record)
                    }
                    try? modelContext.save()
                }
            }
        }
        .accessibilityIdentifier("history_list")
        .navigationTitle("History")
        .navigationDestination(for: TranscriptionRecord.self) { record in
            TranscriptionDetailView(record: record)
        }
    }
}

private struct HistoryRowView: View {
    let record: TranscriptionRecord

    private var previewText: String {
        let prefix = record.text.prefix(100)
        return record.text.count > 100 ? prefix + "..." : String(prefix)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(previewText)
                .font(.body)
                .lineLimit(2)

            HStack {
                if record.audioFileName != nil {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                }
                Text(record.createdAt, style: .date)
                Text("\u{2014}")
                Text(FormatUtils.formatDuration(record.durationSeconds))
                Spacer()
                Text(record.modelUsed)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
