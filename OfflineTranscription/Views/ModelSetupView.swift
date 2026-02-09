import SwiftUI

struct ModelSetupView: View {
    @Environment(WhisperService.self) private var whisperService
    @State private var viewModel: ModelManagementViewModel?

    private var isBusy: Bool {
        whisperService.modelState == .downloading || whisperService.modelState == .loading
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                headerSection
                modelPickerSection
                Spacer()
                statusSection
            }
            .accessibilityIdentifier("model_setup_view")
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            viewModel = ModelManagementViewModel(whisperService: whisperService)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            Text("Offline Transcription")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("setup_title")
            Text(
                "Download a speech recognition model to get started. Models are stored on-device for fully offline use."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .padding(.top, 40)
    }

    private var modelPickerSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ModelInfo.modelsByFamily, id: \.family) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.family.displayName)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ForEach(group.models) { model in
                            modelRow(model)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        let isSelectedModel = whisperService.selectedModel.id == model.id

        ModelPickerRow(
            model: model,
            isSelected: isSelectedModel,
            isDownloaded: viewModel?.isModelDownloaded(model) ?? false,
            isDownloading: whisperService.modelState == .downloading && isSelectedModel,
            downloadProgress: whisperService.downloadProgress,
            isLoading: whisperService.modelState == .loading && isSelectedModel
        ) {
            whisperService.selectedModel = model
            Task {
                await viewModel?.downloadAndSetup()
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 16) {
            if whisperService.modelState != .downloading && whisperService.modelState != .loading {
                Text("Tap a model to download and get started.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("setup_prompt")
            }

            if let error = whisperService.lastError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 32)
    }
}
