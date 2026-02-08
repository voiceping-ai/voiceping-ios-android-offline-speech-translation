import Foundation
import AVFoundation

@MainActor
final class NativeTTSService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeDumpers: [UUID: SpeechAudioDumper] = [:]
    private(set) var latestEvidenceFileURL: URL?
    private(set) var isSpeaking: Bool = false
    var onPlaybackStateChanged: ((Bool) -> Void)?
    private let evidenceDirectory: URL

    override init() {
        let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        evidenceDirectory = baseDir.appendingPathComponent("tts_evidence", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(
            at: evidenceDirectory,
            withIntermediateDirectories: true
        )
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

        // Save synthesized speech as offline evidence.
        let dumpUtterance = configuredUtterance(
            text: normalized,
            languageCode: languageCode,
            rate: normalizedRate,
            voiceIdentifier: voiceIdentifier
        )
        dumpToFile(utterance: dumpUtterance, languageCode: languageCode)
    }

    func latestEvidenceFilePath() -> String? {
        latestEvidenceFileURL?.path
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

    private func dumpToFile(utterance: AVSpeechUtterance, languageCode: String) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let sanitizedLanguage = languageCode.replacingOccurrences(of: "-", with: "_")
        let fileURL = evidenceDirectory
            .appendingPathComponent("tts_\(timestamp)_\(sanitizedLanguage)")
            .appendingPathExtension("caf")
        let token = UUID()
        let dumper = SpeechAudioDumper(utterance: utterance, outputURL: fileURL) { [weak self] succeeded in
            Task { @MainActor in
                guard let self else { return }
                if succeeded {
                    self.latestEvidenceFileURL = fileURL
                }
                self.activeDumpers[token] = nil
            }
        }
        activeDumpers[token] = dumper
        dumper.start()
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

private final class SpeechAudioDumper {
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let outputURL: URL
    private let completion: (Bool) -> Void
    private var audioFile: AVAudioFile?
    private var hasWrittenFrames = false
    private var failed = false
    private var didFinish = false

    init(utterance: AVSpeechUtterance, outputURL: URL, completion: @escaping (Bool) -> Void) {
        self.utterance = utterance
        self.outputURL = outputURL
        self.completion = completion
    }

    func start() {
        synthesizer.write(utterance) { [weak self] buffer in
            self?.handle(buffer: buffer)
        }
    }

    private func handle(buffer: AVAudioBuffer) {
        guard !didFinish else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }

        if pcm.frameLength == 0 {
            didFinish = true
            completion(hasWrittenFrames && !failed)
            return
        }

        if audioFile == nil {
            do {
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            } catch {
                failed = true
                didFinish = true
                completion(false)
                return
            }
        }

        do {
            try audioFile?.write(from: pcm)
            hasWrittenFrames = true
        } catch {
            failed = true
            didFinish = true
            completion(false)
        }
    }
}
