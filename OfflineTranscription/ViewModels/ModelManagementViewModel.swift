import Foundation
import Observation

@MainActor
@Observable
final class ModelManagementViewModel {
    let whisperService: WhisperService

    var selectedModel: ModelInfo {
        get { whisperService.selectedModel }
        set { whisperService.selectedModel = newValue }
    }

    var isDownloading: Bool {
        whisperService.modelState == .downloading
    }

    var isLoading: Bool {
        whisperService.modelState == .loading
    }

    var isReady: Bool {
        whisperService.modelState == .loaded
    }

    var downloadProgress: Double {
        whisperService.downloadProgress
    }

    var errorMessage: String? {
        whisperService.lastError?.localizedDescription
    }

    init(whisperService: WhisperService) {
        self.whisperService = whisperService
    }

    func downloadAndSetup() async {
        await whisperService.setupModel()
    }

    func switchModel(to model: ModelInfo) async {
        await whisperService.switchModel(to: model)
    }

    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        whisperService.isModelDownloaded(model)
    }
}
