import Foundation

enum WAVWriter {
    /// Write 16kHz mono 16-bit PCM WAV file from Float32 samples normalized to [-1, 1].
    static func write(samples: [Float], sampleRate: Int = 16000, to url: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(blockAlign))
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(fileSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // PCM
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)

        // Convert Float32 → Int16 PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            data.appendLittleEndian(int16Value)
        }

        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafePointer(to: &le) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }
}
