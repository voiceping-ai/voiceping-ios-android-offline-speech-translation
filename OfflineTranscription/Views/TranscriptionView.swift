import SwiftUI
import SwiftData
#if canImport(Translation)
import Translation
#endif

struct TranscriptionView: View {
    @Environment(WhisperService.self) private var whisperService
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: TranscriptionViewModel?
    @State private var showSettings = false
    @State private var showSaveConfirmation = false
    @State private var recordingStartDate: Date?
    @State private var didAutoTest = false

    var body: some View {
        VStack(spacing: 0) {
            // Transcription text area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let vm = viewModel {
                            let confirmedText = vm.confirmedText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let hypothesisText = vm.hypothesisText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let translatedConfirmedText = vm.translatedConfirmedText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let translatedHypothesisText = vm.translatedHypothesisText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let translationWarning = (vm.translationWarning ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)

                            if !confirmedText.isEmpty {
                                Text(confirmedText)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("confirmed_text")
                            }

                            if !hypothesisText.isEmpty {
                                Text(hypothesisText)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }

                            if vm.translationEnabled
                                && (!translatedConfirmedText.isEmpty || !translatedHypothesisText.isEmpty)
                            {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("Translation (\(whisperService.translationTargetLanguageCode))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)

                                if !translatedConfirmedText.isEmpty {
                                    Text(translatedConfirmedText)
                                        .font(.body)
                                        .foregroundStyle(.blue)
                                }

                                if !translatedHypothesisText.isEmpty {
                                    Text(translatedHypothesisText)
                                        .font(.body)
                                        .foregroundStyle(.blue.opacity(0.8))
                                        .italic()
                                }

                                if !translationWarning.isEmpty {
                                    Text("Warning: \(translationWarning)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .padding(.top, 4)
                                }
                            } else if vm.translationEnabled
                                && vm.isRecording
                                && (!confirmedText.isEmpty || !hypothesisText.isEmpty)
                            {
                                Text("Translating...")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else if vm.translationEnabled
                                && !translationWarning.isEmpty
                                && (!confirmedText.isEmpty || !hypothesisText.isEmpty)
                            {
                                Text("Warning: \(translationWarning)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            if confirmedText.isEmpty && hypothesisText.isEmpty
                                && !vm.isRecording && !vm.isInterrupted
                            {
                                if vm.showPermissionDenied {
                                    permissionDeniedView(vm: vm)
                                } else {
                                    Text("Tap the microphone button to start transcribing.")
                                        .font(.body)
                                        .foregroundStyle(.tertiary)
                                        .accessibilityIdentifier("idle_placeholder")
                                }
                            }

                            if vm.isRecording && confirmedText.isEmpty
                                && hypothesisText.isEmpty
                            {
                                Text("Listening...")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityIdentifier("listening_text")
                            }

                            if vm.isInterrupted {
                                interruptedBanner
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                .onChange(of: viewModel?.fullText ?? "") { _, _ in
                    guard viewModel?.isRecording == true else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: viewModel?.isRecording ?? false) { _, isRecording in
                    if isRecording {
                        recordingStartDate = Date()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        recordingStartDate = nil
                    }
                }
            }

            Divider()

            // Audio visualizer
            if let vm = viewModel, vm.isRecording {
                AudioVisualizerView(energyLevels: vm.bufferEnergy)
                    .frame(height: 60)
                    .padding(.horizontal)
            }

            // Stats bar
            if let vm = viewModel, vm.isRecording {
                HStack {
                    Label(
                        FormatUtils.formatDuration(vm.bufferSeconds),
                        systemImage: "clock"
                    )
                    Spacer()
                    if vm.tokensPerSecond > 0 {
                        Text(String(format: "%.1f tok/s", vm.tokensPerSecond))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)
                .accessibilityIdentifier("stats_bar")
            }

            // Model info (always visible)
            if let vm = viewModel {
                VStack(spacing: 2) {
                    Text("\(vm.selectedModel.displayName) · \(vm.selectedModel.languages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(vm.selectedModel.inferenceMethodLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("model_info_label")
            }

            // Resource stats (always visible)
            if let vm = viewModel {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed: Int = if let start = recordingStartDate, vm.isRecording {
                        Int(context.date.timeIntervalSince(start))
                    } else {
                        0
                    }
                    HStack(spacing: 16) {
                        if vm.isRecording {
                            Text("\(elapsed)s")
                        }
                        Text(String(format: "CPU %.0f%%", vm.cpuPercent))
                        Text(String(format: "RAM %.0f MB", vm.memoryMB))
                        if vm.tokensPerSecond > 0 {
                            Text(String(format: "%.1f tok/s", vm.tokensPerSecond))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }

            // Translation & speech controls on home
            if let vm = viewModel {
                @Bindable var service = whisperService
                HomeLanguageSpeechCard(
                    translationEnabled: $service.translationEnabled,
                    speakTranslatedAudio: $service.speakTranslatedAudio,
                    sourceLanguageCode: $service.translationSourceLanguageCode,
                    targetLanguageCode: $service.translationTargetLanguageCode,
                    ttsRate: $service.ttsRate,
                    translatedConfirmedText: vm.translatedConfirmedText,
                    translatedHypothesisText: vm.translatedHypothesisText,
                    translationWarning: vm.translationWarning,
                    translationModelStatus: whisperService.translationModelStatus
                )
                .padding(.horizontal)
                .padding(.top, 4)
            }

            // Controls
            HStack(spacing: 32) {
                if let vm = viewModel, !vm.isRecording && !vm.fullText.isEmpty {
                    Button {
                        if vm.saveTranscription(using: modelContext) {
                            showSaveConfirmation = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title2)
                    }
                    .accessibilityIdentifier("save_button")
                }

                #if DEBUG
                if let vm = viewModel, !vm.isRecording {
                    Button {
                        vm.transcribeTestFile("/tmp/test_speech.wav")
                    } label: {
                        Image(systemName: "doc.text.fill")
                            .font(.title2)
                    }
                    .accessibilityIdentifier("test_file_button")
                }
                #endif

                RecordButton(
                    isRecording: viewModel?.isRecording ?? false
                ) {
                    Task {
                        await viewModel?.toggleRecording()
                    }
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                        .font(.title2)
                }
                .accessibilityIdentifier("settings_button")
            }
            .padding()
        }
        .navigationTitle("Transcribe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = viewModel?.fullText ?? ""
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }
                    .disabled(viewModel == nil || (viewModel?.fullText.isEmpty ?? true))
                    Button(role: .destructive) {
                        viewModel?.clearTranscription()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(viewModel == nil || (viewModel?.fullText.isEmpty ?? true))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("overflow_menu")
            }
        }
        .sheet(isPresented: $showSettings) {
            ModelSettingsSheet()
        }
        .alert("Saved", isPresented: $showSaveConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Transcription saved to history.")
        }
        .alert(
            "Error",
            isPresented: .init(
                get: { viewModel?.showError ?? false },
                set: { newValue in
                    guard viewModel != nil else { return }
                    viewModel?.showError = newValue
                }
            )
        ) {
            if viewModel?.showPermissionDenied == true {
                Button("Open Settings") { viewModel?.openSettings() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(viewModel?.errorMessage ?? "")
        }
        .onChange(of: whisperService.lastError != nil) { _, hasError in
            guard hasError, viewModel != nil else { return }
            viewModel?.surfaceEngineError()
        }
        .onAppear {
            if viewModel == nil {
                viewModel = TranscriptionViewModel(whisperService: whisperService)
            }
        }
        #if canImport(Translation)
        .background {
            if #available(iOS 18.0, *) {
                #if targetEnvironment(simulator)
                SimulatorTranslationBridgeFallbackView(whisperService: whisperService)
                #else
                TranslationBridgeView(whisperService: whisperService)
                #endif
            }
        }
        #endif
        #if DEBUG
        .task {
            // Auto-test: wait for model to load, then transcribe test file
            guard ProcessInfo.processInfo.arguments.contains("--auto-test") else { return }
            let args = ProcessInfo.processInfo.arguments
            let argsDump = args.joined(separator: "\n")
            try? argsDump.write(
                to: URL(fileURLWithPath: "/tmp/ios_args_runtime.txt"),
                atomically: true,
                encoding: .utf8
            )
            let sourceCode = argumentValue("--translation-source", in: args) ?? "en"
            let targetCode = argumentValue("--translation-target", in: args) ?? "ja"
            whisperService.translationEnabled = true
            whisperService.speakTranslatedAudio = true
            whisperService.translationSourceLanguageCode = sourceCode
            whisperService.translationTargetLanguageCode = targetCode
            // Wait until model is loaded
            while whisperService.modelState != .loaded {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !didAutoTest else { return }
            didAutoTest = true
            try? await Task.sleep(for: .milliseconds(500))
            viewModel?.transcribeTestFile("/tmp/test_speech.wav")
        }
        #endif
    }

    private func argumentValue(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    // MARK: - Subviews

    private func permissionDeniedView(vm: TranscriptionViewModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Microphone access is required to transcribe speech.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                vm.openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var interruptedBanner: some View {
        HStack {
            Image(systemName: "phone.fill")
            Text("Recording interrupted. Tap stop to finish.")
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings Sheet

struct ModelSettingsSheet: View {
    @Environment(WhisperService.self) private var whisperService
    @Environment(\.dismiss) private var dismiss
    @State private var isSwitching = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Model") {
                    HStack {
                        Text(whisperService.selectedModel.displayName)
                            .accessibilityIdentifier("settings_current_model")
                        Spacer()
                        Text(whisperService.selectedModel.parameterCount)
                            .foregroundStyle(.secondary)
                    }
                    Text("Inference: \(whisperService.selectedModel.inferenceMethodLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isSwitching {
                    Section {
                        if whisperService.modelState == .downloading {
                            VStack(spacing: 8) {
                                ProgressView(
                                    value: whisperService.downloadProgress
                                ) {
                                    Text(
                                        "Downloading \(whisperService.selectedModel.displayName)..."
                                    )
                                    .font(.subheadline)
                                }
                                Text(
                                    "\(Int(whisperService.downloadProgress * 100))%"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                ProgressView()
                                Text("Loading model...")
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }

                if !isSwitching, let error = whisperService.lastError {
                    Section {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                ForEach(ModelInfo.modelsByFamily, id: \.family) { group in
                    Section(group.family.displayName) {
                        ForEach(group.models) { model in
                            Button {
                                isSwitching = true
                                Task {
                                    await whisperService.switchModel(to: model)
                                    isSwitching = false
                                    if whisperService.modelState == .loaded {
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(model.displayName)
                                        Text(model.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Inference: \(model.inferenceMethodLabel)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text(model.sizeOnDisk)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(model.languages)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("model_row_\(model.id)")
                            .disabled(
                                model.id == whisperService.selectedModel.id
                                || isSwitching
                            )
                        }
                    }
                }

                Section("Transcription Settings") {
                    @Bindable var service = whisperService
                    Toggle("Voice Activity Detection", isOn: $service.useVAD)
                        .accessibilityIdentifier("vad_toggle")
                    Toggle("Enable Timestamps", isOn: $service.enableTimestamps)
                        .accessibilityIdentifier("timestamps_toggle")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings_done_button")
                        .disabled(isSwitching)
                }
            }
        }
    }
}

private struct TranslationLanguageOption: Identifiable {
    let id: String
    let displayName: String

    init(code: String, name: String) {
        self.id = code
        self.displayName = "\(name) (\(code))"
    }
}

private enum TranslationLanguageCatalog {
    static let options: [TranslationLanguageOption] = [
        .init(code: "en", name: "English"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ru", name: "Russian"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "th", name: "Thai"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "pl", name: "Polish"),
    ]

    static func displayName(for code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let option = options.first(where: { $0.id.lowercased() == normalized }) {
            return option.displayName
        }
        return normalized.isEmpty ? "Select language" : normalized
    }
}

private struct LanguageMenuField: View {
    let title: String
    @Binding var selectedCode: String
    let enabled: Bool

    private var normalizedSelectedCode: String {
        selectedCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(TranslationLanguageCatalog.options) { option in
                    Button {
                        selectedCode = option.id
                    } label: {
                        if normalizedSelectedCode == option.id.lowercased() {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(TranslationLanguageCatalog.displayName(for: selectedCode))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemBackground))
                )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1.0 : 0.6)
        }
    }
}

private struct HomeLanguageSpeechCard: View {
    @Binding var translationEnabled: Bool
    @Binding var speakTranslatedAudio: Bool
    @Binding var sourceLanguageCode: String
    @Binding var targetLanguageCode: String
    @Binding var ttsRate: Float
    let translatedConfirmedText: String
    let translatedHypothesisText: String
    let translationWarning: String?
    let translationModelStatus: TranslationModelStatus

    private var ttsText: String {
        let confirmed = translatedConfirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hypothesis = translatedHypothesisText.trimmingCharacters(in: .whitespacesAndNewlines)
        return [confirmed, hypothesis]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Language & Speech")
                .font(.headline)

            Toggle("Enable Translation", isOn: $translationEnabled)
                .accessibilityIdentifier("translation_toggle")
            Toggle("Speak Translated Audio", isOn: $speakTranslatedAudio)
                .disabled(!translationEnabled)

            HStack(alignment: .top, spacing: 8) {
                LanguageMenuField(
                    title: "Source",
                    selectedCode: $sourceLanguageCode,
                    enabled: translationEnabled
                )
                .frame(maxWidth: .infinity)

                LanguageMenuField(
                    title: "Target",
                    selectedCode: $targetLanguageCode,
                    enabled: translationEnabled
                )
                .frame(maxWidth: .infinity)
            }

            // Inline translation model status
            if translationEnabled {
                translationModelStatusRow
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Speech rate: \(ttsRate, format: .number.precision(.fractionLength(2)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $ttsRate, in: 0.25...2.0)
                    .disabled(!translationEnabled || !speakTranslatedAudio)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("TTS Text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ttsText.isEmpty ? "No translated text yet." : ttsText)
                    .font(.caption)
                    .foregroundStyle(ttsText.isEmpty ? .tertiary : .primary)
                    .lineLimit(3)
            }

            if let warning = translationWarning,
               !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text("Warning: \(warning)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var translationModelStatusRow: some View {
        switch translationModelStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking translation availability...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading translation models...")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Translation ready")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .unsupported:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Language pair not supported")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Download failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: - Translation Bridge

#if canImport(Translation)
/// Simulator fallback bridge: never opens Translation framework tasks that show
/// unsupported-device modal; keeps translation in inline warning/fallback mode.
@available(iOS 18.0, *)
struct SimulatorTranslationBridgeFallbackView: View {
    let whisperService: WhisperService

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { refreshState() }
            .onChange(of: whisperService.translationEnabled) { _, _ in refreshState() }
            .onChange(of: whisperService.translationSourceLanguageCode) { _, _ in refreshState() }
            .onChange(of: whisperService.translationTargetLanguageCode) { _, _ in refreshState() }
    }

    private func refreshState() {
        whisperService.setTranslationSession(nil)

        guard whisperService.translationEnabled else {
            whisperService.setTranslationModelStatus(.unknown)
            return
        }

        let src = whisperService.translationSourceLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tgt = whisperService.translationTargetLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !tgt.isEmpty else {
            whisperService.setTranslationModelStatus(.unknown)
            return
        }

        if src.caseInsensitiveCompare(tgt) == .orderedSame {
            whisperService.setTranslationModelStatus(.ready)
        } else {
            whisperService.setTranslationModelStatus(
                .failed("On-device Translation API is unavailable on iOS Simulator. Using inline fallback text.")
            )
        }
    }
}

/// Hidden SwiftUI view that manages the Apple Translation session lifecycle.
/// `.translationTask()` is the only way to obtain a `TranslationSession`;
/// this bridge keeps the session alive and passes it to `WhisperService`.
@available(iOS 18.0, *)
struct TranslationBridgeView: View {
    let whisperService: WhisperService
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(config) { session in
                whisperService.setTranslationSession(session)
                defer { whisperService.setTranslationSession(nil) }

                // Check availability and prepare (download) models if needed.
                await prepareModels(session: session)

                // Keep the closure alive so the session remains valid.
                // It is cancelled automatically when config changes or the view disappears.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
            .onAppear { updateConfig() }
            .onChange(of: whisperService.translationEnabled) { _, _ in updateConfig() }
            .onChange(of: whisperService.translationSourceLanguageCode) { _, _ in updateConfig() }
            .onChange(of: whisperService.translationTargetLanguageCode) { _, _ in updateConfig() }
    }

    private func prepareModels(session: TranslationSession) async {
        let src = Locale.Language(identifier: whisperService.translationSourceLanguageCode)
        let tgt = Locale.Language(identifier: whisperService.translationTargetLanguageCode)

        whisperService.setTranslationModelStatus(.checking)

        let availability = LanguageAvailability()
        let status = await availability.status(from: src, to: tgt)

        switch status {
        case .installed:
            whisperService.setTranslationModelStatus(.ready)

        case .supported:
            // Models need downloading — prepareTranslation() triggers the system consent dialog
            // then downloads in the background. Show inline progress while it runs.
            whisperService.setTranslationModelStatus(.downloading)
            do {
                try await session.prepareTranslation()
                guard !Task.isCancelled else { return }
                whisperService.setTranslationModelStatus(.ready)
            } catch {
                guard !Task.isCancelled else { return }
                whisperService.setTranslationModelStatus(
                    .failed(error.localizedDescription)
                )
            }

        case .unsupported:
            whisperService.setTranslationModelStatus(.unsupported)

        @unknown default:
            whisperService.setTranslationModelStatus(.unknown)
        }
    }

    private func updateConfig() {
        guard whisperService.translationEnabled else {
            config = nil
            return
        }
        let src = whisperService.translationSourceLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tgt = whisperService.translationTargetLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !tgt.isEmpty, src != tgt else {
            config = nil
            return
        }
        config = TranslationSession.Configuration(
            source: Locale.Language(identifier: src),
            target: Locale.Language(identifier: tgt)
        )
    }
}
#endif
