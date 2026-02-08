import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayerViewModel: NSObject {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var waveformBars: [Float] = []

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?

    let audioURL: URL

    init(audioURL: URL) {
        self.audioURL = audioURL
        super.init()
        loadAudio()
    }

    // MARK: - Loading

    private func loadAudio() {
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            generateWaveform()
        } catch {
            NSLog("[AudioPlayer] Failed to load audio: \(error)")
        }
    }

    // MARK: - Playback

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startDisplayLink()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopDisplayLink()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let time = fraction * player.duration
        player.currentTime = time
        currentTime = time
    }

    // MARK: - Waveform

    private func generateWaveform() {
        guard let data = try? Data(contentsOf: audioURL), data.count > 44 else {
            waveformBars = Array(repeating: 0, count: 200)
            return
        }

        let barCount = 200
        let sampleCount = (data.count - 44) / 2
        let samplesPerBar = max(1, sampleCount / barCount)

        var bars: [Float] = []
        bars.reserveCapacity(barCount)

        for barIndex in 0..<barCount {
            let startSample = barIndex * samplesPerBar
            let endSample = min(startSample + samplesPerBar, sampleCount)
            guard startSample < sampleCount else {
                bars.append(0)
                continue
            }

            var sumSquares: Float = 0
            for i in startSample..<endSample {
                let byteOffset = 44 + i * 2
                guard byteOffset + 1 < data.count else { break }
                let int16 = data.subdata(in: byteOffset..<byteOffset + 2)
                    .withUnsafeBytes { $0.load(as: Int16.self).littleEndian }
                let floatVal = Float(int16) / 32767.0
                sumSquares += floatVal * floatVal
            }
            let count = Float(max(1, endSample - startSample))
            bars.append(sqrt(sumSquares / count))
        }

        let maxBar = bars.max() ?? 1.0
        waveformBars = maxBar > 0 ? bars.map { $0 / maxBar } : bars
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(updateTime))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateTime() {
        currentTime = player?.currentTime ?? 0
    }

    deinit {
        // CADisplayLink and AVAudioPlayer clean up on deallocation
    }
}

extension AudioPlayerViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.stopDisplayLink()
            self?.currentTime = 0
            self?.player?.currentTime = 0
        }
    }
}
