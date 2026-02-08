import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    @State private var showExportError = false

    private var audioURL: URL? {
        guard let audioFileName = record.audioFileName else { return nil }
        let url = SessionFileManager.resolveAudioURL(audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataHeader

                // Waveform player (only if audio exists)
                if let url = audioURL {
                    WaveformPlaybackView(audioURL: url)
                        .frame(height: 80)
                        .accessibilityIdentifier("waveform_player")
                }

                Divider()

                Text(record.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail_text")
            }
            .padding()
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if audioURL != nil {
                    Button { exportZIP() } label: {
                        Image(systemName: "arrow.down.doc.fill")
                    }
                    .accessibilityIdentifier("export_zip_button")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: record.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = record.text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Metadata Header

    private var metadataHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    record.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                Spacer()
                Label(
                    FormatUtils.formatDuration(record.durationSeconds),
                    systemImage: "clock"
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack {
                Text("Model: \(record.modelUsed)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
                Spacer()
            }
        }
    }

    // MARK: - ZIP Export

    private func exportZIP() {
        let metadata: [String: Any] = [
            "id": record.id.uuidString,
            "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
            "durationSeconds": record.durationSeconds,
            "modelUsed": record.modelUsed,
            "language": record.language ?? "unknown",
        ]

        let bundle = ZIPExporter.SessionBundle(
            transcriptText: record.text,
            metadata: metadata,
            audioFileURL: audioURL
        )

        do {
            let zipURL = try ZIPExporter.exportSession(bundle)
            let activityVC = UIActivityViewController(
                activityItems: [zipURL],
                applicationActivities: nil
            )
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        } catch {
            NSLog("[Export] ZIP export failed: \(error)")
            showExportError = true
        }
    }
}
