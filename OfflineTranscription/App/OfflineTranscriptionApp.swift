import SwiftUI
import SwiftData

@main
struct OfflineTranscriptionApp: App {
    let whisperService: WhisperService

    init() {
        // Clear persisted state BEFORE WhisperService.init() reads UserDefaults
        if ProcessInfo.processInfo.arguments.contains("--reset-state") {
            UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        }
        whisperService = WhisperService()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(whisperService)
        }
        .modelContainer(for: TranscriptionRecord.self)
    }
}

struct RootView: View {
    @Environment(WhisperService.self) private var whisperService
    @Environment(\.modelContext) private var modelContext

    private static var autoTestModelId: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--model-id"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    var body: some View {
        Group {
            switch whisperService.modelState {
            case .loaded:
                MainTabView()
            default:
                // Auto-download/load progress view
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)
                    Text("Offline Transcription")
                        .font(.largeTitle.bold())

                    if whisperService.modelState == .downloading {
                        ProgressView(value: whisperService.downloadProgress) {
                            Text("Downloading model...")
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 40)
                        Text("\(Int(whisperService.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if whisperService.modelState == .loading {
                        ProgressView("Loading model...")
                    } else {
                        ProgressView("Preparing...")
                    }

                    if let error = whisperService.lastError {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    Spacer()
                    AppVersionLabel()
                        .padding(.bottom, 8)
                }
            }
        }
        .task {
            let resetState = ProcessInfo.processInfo.arguments.contains("--reset-state")

            // --reset-state: clear UserDefaults + SwiftData for clean UI test runs
            if resetState {
                UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
                try? modelContext.delete(model: TranscriptionRecord.self)
            }

            if let modelId = Self.autoTestModelId,
               let model = ModelInfo.availableModels.first(where: { $0.id == modelId }) {
                await whisperService.switchModel(to: model)
            } else {
                // Auto-download and load the default model
                await whisperService.setupModel()
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                TranscriptionView()
            }
            .tabItem {
                Label("Transcribe", systemImage: "mic.fill")
            }

            NavigationStack {
                TranscriptionHistoryView()
            }
            .tabItem {
                Label("History", systemImage: "clock.fill")
            }
        }
        .accessibilityIdentifier("main_tab_view")
    }
}
