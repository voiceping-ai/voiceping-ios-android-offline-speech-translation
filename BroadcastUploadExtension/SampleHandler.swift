import ReplayKit
import CoreMedia
import AudioToolbox

/// Broadcast Upload Extension handler — receives system audio from ReplayKit
/// and writes PCM Float32 to a shared ring buffer for the main app to read.
class SampleHandler: RPBroadcastSampleHandler {
    private var ringBuffer: SharedAudioRingBuffer?
    private var hasLoggedFormat = false
    private var totalSamplesWritten = 0
    private var diagnosticLines: [String] = []
    private var stopCheckTimer: DispatchSourceTimer?
    private var didFinish = false

    /// Write diagnostic info to App Group container for debugging.
    private func writeDiagnostic(_ line: String) {
        diagnosticLines.append(line)
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAudioRingBuffer.appGroupID
        )?.appendingPathComponent("broadcast_diag.txt") else { return }
        try? diagnosticLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("[SampleHandler] broadcastStarted — setupInfo=%@", String(describing: setupInfo))
        diagnosticLines = []
        totalSamplesWritten = 0
        hasLoggedFormat = false
        didFinish = false
        writeDiagnostic("broadcastStarted at \(Date())")
        ringBuffer = SharedAudioRingBuffer(isProducer: true)
        let rbOK = ringBuffer != nil
        NSLog("[SampleHandler] ringBuffer initialized: %@", rbOK ? "YES" : "NO (App Group failed!)")
        writeDiagnostic("ringBuffer init: \(rbOK)")
        ringBuffer?.setActive(true)

        // Listen for stop request from main app
        registerStopNotification()
        startStopCheckTimer()

        // Notify main app that broadcast started
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.voiceping.translate.broadcastStarted" as CFString),
            nil, nil, true
        )
        NSLog("[SampleHandler] Posted broadcastStarted notification")
    }

    override func broadcastPaused() {
        NSLog("[SampleHandler] broadcastPaused")
        ringBuffer?.setActive(false)
    }

    override func broadcastResumed() {
        NSLog("[SampleHandler] broadcastResumed")
        ringBuffer?.setActive(true)
    }

    override func broadcastFinished() {
        NSLog("[SampleHandler] broadcastFinished — totalSamples=%d (%.1fs)", totalSamplesWritten, Float(totalSamplesWritten) / 16000)
        writeDiagnostic("broadcastFinished at \(Date()), totalSamples=\(totalSamplesWritten) (\(String(format: "%.1f", Float(totalSamplesWritten) / 16000))s)")
        stopCheckTimer?.cancel()
        stopCheckTimer = nil
        unregisterStopNotification()
        ringBuffer?.setActive(false)
        ringBuffer = nil

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.voiceping.translate.broadcastStopped" as CFString),
            nil, nil, true
        )
    }

    // MARK: - Stop Notification

    private func registerStopNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                NSLog("[SampleHandler] Received stopBroadcast request from main app")
                DispatchQueue.main.async {
                    guard !handler.didFinish else { return }
                    handler.didFinish = true
                    handler.finishBroadcastWithError(NSError(
                        domain: "com.voiceping.translate",
                        code: 0,
                        userInfo: [NSLocalizedFailureReasonErrorKey: "Recording stopped by user"]
                    ))
                }
            },
            "com.voiceping.translate.stopBroadcast" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterStopNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - Timer-based Stop Check

    /// Polls requestStop every 200ms so we can stop even when no app audio is flowing.
    private func startStopCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.didFinish else { return }
            guard let rb = self.ringBuffer, rb.requestStop else { return }
            NSLog("[SampleHandler] Timer detected requestStop — finishing broadcast")
            self.writeDiagnostic("timer requestStop at \(Date()), totalSamples=\(self.totalSamplesWritten)")
            self.didFinish = true
            self.finishBroadcastWithError(NSError(
                domain: "com.voiceping.translate",
                code: 0,
                userInfo: [NSLocalizedFailureReasonErrorKey: "Recording stopped by user"]
            ))
        }
        timer.resume()
        stopCheckTimer = timer
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            // App audio — this is what we want to transcribe
            guard let ringBuffer else {
                NSLog("[SampleHandler] .audioApp but ringBuffer is nil!")
                return
            }

            // Check if the main app has requested us to stop (via shared memory flag)
            if !didFinish && ringBuffer.requestStop {
                NSLog("[SampleHandler] requestStop flag detected — finishing broadcast")
                writeDiagnostic("requestStop detected at \(Date()), totalSamples=\(totalSamplesWritten)")
                didFinish = true
                finishBroadcastWithError(NSError(
                    domain: "com.voiceping.translate",
                    code: 0,
                    userInfo: [NSLocalizedFailureReasonErrorKey: "Recording stopped by user"]
                ))
                return
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
            guard let asbd = format.map({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { return }
            guard let asbd else { return }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let dataPointer else { return }

            let sampleRate = asbd.mSampleRate
            let channelCount = Int(asbd.mChannelsPerFrame)
            let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
            let sampleCount = length / (bytesPerSample * channelCount)

            if !hasLoggedFormat {
                hasLoggedFormat = true
                let formatLog = "format: rate=\(sampleRate) ch=\(channelCount) bps=\(bytesPerSample) float=\(isFloat) nonInterleaved=\(isNonInterleaved) frames=\(sampleCount) len=\(length) flags=0x\(String(asbd.mFormatFlags, radix: 16)) bpf=\(asbd.mBytesPerFrame) bpp=\(asbd.mBytesPerPacket)"
                NSLog("[SampleHandler] %@", formatLog)
                writeDiagnostic(formatLog)
            }

            // Convert to mono Float32
            var monoSamples = [Float](repeating: 0, count: sampleCount)

            if isFloat && bytesPerSample == 4 {
                dataPointer.withMemoryRebound(to: UInt32.self, capacity: sampleCount * channelCount) { rawPtr in
                    func readFloat(_ index: Int) -> Float {
                        var bits = rawPtr[index]
                        if isBigEndian { bits = bits.byteSwapped }
                        return Float(bitPattern: bits)
                    }

                    if channelCount == 1 {
                        for i in 0..<sampleCount {
                            monoSamples[i] = readFloat(i)
                        }
                    } else if isNonInterleaved {
                        for i in 0..<sampleCount {
                            var sum: Float = 0
                            for ch in 0..<channelCount {
                                sum += readFloat(ch * sampleCount + i)
                            }
                            monoSamples[i] = sum / Float(channelCount)
                        }
                    } else {
                        for i in 0..<sampleCount {
                            var sum: Float = 0
                            for ch in 0..<channelCount {
                                sum += readFloat(i * channelCount + ch)
                            }
                            monoSamples[i] = sum / Float(channelCount)
                        }
                    }
                }
            } else if !isFloat && bytesPerSample == 2 {
                dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount * channelCount) { int16Ptr in
                    for i in 0..<sampleCount {
                        var sum: Float = 0
                        if isNonInterleaved {
                            for ch in 0..<channelCount {
                                var raw = int16Ptr[ch * sampleCount + i]
                                if isBigEndian { raw = Int16(bigEndian: raw) }
                                sum += Float(raw) / 32768.0
                            }
                        } else {
                            for ch in 0..<channelCount {
                                var raw = int16Ptr[i * channelCount + ch]
                                if isBigEndian { raw = Int16(bigEndian: raw) }
                                sum += Float(raw) / 32768.0
                            }
                        }
                        monoSamples[i] = sum / Float(channelCount)
                    }
                }
            }

            // Resample to 16kHz if needed
            let preResampleCount = monoSamples.count
            if abs(sampleRate - 16000) > 1.0 {
                monoSamples = resample(monoSamples, from: sampleRate, to: 16000)
            }

            // Log sample statistics periodically
            totalSamplesWritten += monoSamples.count
            if totalSamplesWritten % 16000 < monoSamples.count {
                let rms = sqrt(monoSamples.reduce(Float(0)) { $0 + $1 * $1 } / max(Float(monoSamples.count), 1))
                let minVal = monoSamples.min() ?? 0
                let maxVal = monoSamples.max() ?? 0
                let first5 = monoSamples.prefix(5).map { String(format: "%.4f", $0) }.joined(separator: ",")
                let statsLog = "t=\(String(format: "%.1f", Float(totalSamplesWritten) / 16000))s preResample=\(preResampleCount) postResample=\(monoSamples.count) rms=\(String(format: "%.5f", rms)) min=\(String(format: "%.4f", minVal)) max=\(String(format: "%.4f", maxVal)) first5=[\(first5)]"
                NSLog("[SampleHandler] %@", statsLog)
                writeDiagnostic(statsLog)
            }

            ringBuffer.write(monoSamples)

            // Notify main app audio is available
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                CFNotificationName("com.voiceping.translate.audioReady" as CFString),
                nil, nil, true
            )

        case .audioMic:
            break
        case .video:
            break
        @unknown default:
            break
        }
    }

    /// Simple linear resampling from source to target sample rate.
    private func resample(_ samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
        let ratio = sourceSR / targetSR
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let idx0 = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx0))
            let idx1 = min(idx0 + 1, samples.count - 1)
            output[i] = samples[idx0] * (1 - frac) + samples[idx1] * frac
        }
        return output
    }
}
