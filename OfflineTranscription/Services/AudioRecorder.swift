import AVFoundation
import Foundation

/// Shared AVAudioEngine-based recorder for sherpa-onnx engines.
/// Captures 16kHz mono Float32 audio and computes RMS energy.
@MainActor
final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private(set) var isRecording = false

    /// Accumulated audio samples at 16 kHz, normalized [-1, 1].
    private(set) var audioSamples: [Float] = []
    /// Per-buffer normalized energy values (0–1 dBFS scale) for visualization and VAD.
    private(set) var relativeEnergy: [Float] = []

    /// Called on the main actor whenever new audio arrives.
    var onNewAudio: (([Float]) -> Void)?

    private static let maxAudioSamples = AudioConstants.maxAudioSamples
    private let sampleRate: Double = AudioConstants.sampleRate
    private let bufferSize: AVAudioFrameCount = AVAudioFrameCount(AudioConstants.bufferSize)
    private static let maxEnergyFrames = AudioConstants.maxEnergyFrames

    func startRecording(captureMode: AudioCaptureMode = .microphone) async throws {
        guard !isRecording else { return }

        // Pre-allocate buffers to reduce reallocations during recording
        // ~60s of audio at 16kHz = 960,000 samples
        if audioSamples.isEmpty {
            audioSamples.reserveCapacity(960_000)
        }

        // Request microphone permission
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AppError.microphonePermissionDenied }

        let session = AVAudioSession.sharedInstance()
        let categoryOptions: AVAudioSession.CategoryOptions
#if compiler(>=6.2)
        categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
#else
        categoryOptions = [.defaultToSpeaker, .allowBluetooth]
#endif
        try session.setCategory(.playAndRecord, mode: .default, options: categoryOptions)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let hwFormat = node.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw AppError.audioSessionSetupFailed(underlying: NSError(
                domain: "AudioRecorder", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format"]
            ))
        }

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.audioSessionSetupFailed(underlying: NSError(
                domain: "AudioRecorder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create target audio format"]
            ))
        }

        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        node.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            var samples: [Float] = []
            if let converter, hwFormat.sampleRate != self.sampleRate || hwFormat.channelCount != 1 {
                // Resample to 16kHz mono
                let ratio = self.sampleRate / hwFormat.sampleRate
                let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

                var error: NSError?
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil, let channelData = outputBuffer.floatChannelData {
                    samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
                }
            } else {
                // Already 16kHz mono
                if let channelData = buffer.floatChannelData {
                    samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
                }
            }

            guard !samples.isEmpty else { return }

            let normalizedEnergy = AudioConstants.normalizedEnergy(of: samples)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioSamples.append(contentsOf: samples)
                // Cap audio samples to prevent unbounded memory growth
                if self.audioSamples.count > Self.maxAudioSamples {
                    self.audioSamples = Array(self.audioSamples.suffix(Self.maxAudioSamples / 2))
                }
                self.relativeEnergy.append(normalizedEnergy)
                // Cap energy array to prevent unbounded growth
                if self.relativeEnergy.count > Self.maxEnergyFrames {
                    self.relativeEnergy = Array(self.relativeEnergy.suffix(Self.maxEnergyFrames / 2))
                }
                self.onNewAudio?(samples)
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.inputNode = node
        self.isRecording = true
        self.audioSamples = []
        self.relativeEnergy = []
    }

    func stopRecording() {
        guard isRecording else { return }
        onNewAudio = nil
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        isRecording = false
    }

    deinit {
        // Safety net: remove audio tap if deallocated while recording.
        // Cannot call stopRecording() directly since deinit is nonisolated.
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
    }

    func clearBuffers() {
        audioSamples = []
        relativeEnergy = []
    }
}
