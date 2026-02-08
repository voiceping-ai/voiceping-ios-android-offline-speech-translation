import Foundation

/// Creates the appropriate ASREngine for a given model.
@MainActor
enum EngineFactory {
    static func makeEngine(for model: ModelInfo) -> ASREngine {
        switch model.engineType {
        case .whisperKit:
            return WhisperKitEngine()
        case .sherpaOnnxOffline:
            return SherpaOnnxOfflineEngine()
        case .sherpaOnnxStreaming:
            return SherpaOnnxStreamingEngine()
        case .fluidAudio:
            return FluidAudioEngine()
        }
    }
}
