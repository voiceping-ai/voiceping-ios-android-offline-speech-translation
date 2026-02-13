import Foundation
import AVFoundation

@MainActor
final class NativeTTSService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking: Bool = false
    var onPlaybackStateChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        updatePlaybackState(false)
    }

    func speak(
        text: String,
        languageCode: String,
        rate: Float,
        voiceIdentifier: String?
    ) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let normalizedRate = min(
            max(rate, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        let speakingUtterance = configuredUtterance(
            text: normalized,
            languageCode: languageCode,
            rate: normalizedRate,
            voiceIdentifier: voiceIdentifier
        )
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            updatePlaybackState(false)
        }
        synthesizer.speak(speakingUtterance)
    }

    func latestEvidenceFilePath() -> String? {
        nil
    }

    private func configuredUtterance(
        text: String,
        languageCode: String,
        rate: Float,
        voiceIdentifier: String?
    ) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        }
        return utterance
    }

    private func updatePlaybackState(_ speaking: Bool) {
        guard isSpeaking != speaking else { return }
        isSpeaking = speaking
        onPlaybackStateChanged?(speaking)
    }
}

extension NativeTTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.updatePlaybackState(true)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.updatePlaybackState(synthesizer.isSpeaking)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.updatePlaybackState(synthesizer.isSpeaking)
        }
    }
}
