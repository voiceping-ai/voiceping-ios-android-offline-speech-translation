import Foundation

/// Lock-free single-producer / single-consumer ring buffer backed by a
/// memory-mapped file in the App Group shared container.
///
/// Used for IPC between the Broadcast Upload Extension (producer) and
/// the main app (consumer). The extension writes PCM Float32 audio at
/// 16kHz mono, and the app reads it for transcription.
///
/// Layout (all little-endian):
///   Bytes 0–3:   writeOffset  (UInt32, sample index modulo capacity)
///   Bytes 4–7:   readOffset   (UInt32, sample index modulo capacity)
///   Bytes 8–11:  sampleRate   (UInt32, always 16000)
///   Bytes 12–15: isActive     (UInt32, 1 = broadcast active, 0 = inactive)
///   Bytes 16–19: requestStop  (UInt32, 1 = app requests broadcast stop)
///   Bytes 20..:  Float32 audio samples (capacity × 4 bytes)
///
/// ~30 seconds at 16kHz = 480,000 samples = 1,920,000 bytes + 20 header = ~1.88 MB
final class SharedAudioRingBuffer {
    static let headerSize = 20
    static let capacity = 480_000  // 30 seconds at 16kHz
    static let totalSize = headerSize + capacity * MemoryLayout<Float>.size
    static let fileName = "audio_ring.pcm"
    static let appGroupID = "group.com.voiceping.translate"

    private let fileHandle: FileHandle
    private let mappedData: UnsafeMutableRawPointer
    private let isProducer: Bool

    /// Initialize the ring buffer.
    /// - Parameter isProducer: `true` for the extension (writer), `false` for the app (reader).
    init?(isProducer: Bool) {
        self.isProducer = isProducer

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            NSLog("[SharedAudioRingBuffer] Failed to get App Group container")
            return nil
        }

        let fileURL = containerURL.appendingPathComponent(Self.fileName)

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forUpdating: fileURL) else {
            NSLog("[SharedAudioRingBuffer] Failed to open file handle")
            return nil
        }

        // Ensure file is the correct size
        handle.seekToEndOfFile()
        let currentSize = handle.offsetInFile
        if currentSize < UInt64(Self.totalSize) {
            handle.truncateFile(atOffset: UInt64(Self.totalSize))
        }

        // Memory-map the file
        let fd = handle.fileDescriptor
        let mapped = mmap(nil, Self.totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED else {
            NSLog("[SharedAudioRingBuffer] mmap failed: %d", errno)
            try? handle.close()
            return nil
        }

        self.fileHandle = handle
        self.mappedData = mapped!

        if isProducer {
            // Initialize header
            writeUInt32(at: 0, value: 0) // writeOffset
            writeUInt32(at: 4, value: 0) // readOffset
            writeUInt32(at: 8, value: 16000) // sampleRate
            writeUInt32(at: 16, value: 0) // requestStop — clear on start
            // isActive is set separately
        }
    }

    deinit {
        munmap(mappedData, Self.totalSize)
        try? fileHandle.close()
    }

    // MARK: - Header accessors

    private func readUInt32(at offset: Int) -> UInt32 {
        mappedData.load(fromByteOffset: offset, as: UInt32.self)
    }

    private func writeUInt32(at offset: Int, value: UInt32) {
        mappedData.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
    }

    var writeOffset: UInt32 {
        get { readUInt32(at: 0) }
        set { writeUInt32(at: 0, value: newValue) }
    }

    var readOffset: UInt32 {
        get { readUInt32(at: 4) }
        set { writeUInt32(at: 4, value: newValue) }
    }

    var isActive: Bool {
        readUInt32(at: 12) == 1
    }

    func setActive(_ active: Bool) {
        writeUInt32(at: 12, value: active ? 1 : 0)
    }

    /// Set by the app (consumer) to request the extension stop the broadcast.
    var requestStop: Bool {
        readUInt32(at: 16) == 1
    }

    func setRequestStop(_ stop: Bool) {
        writeUInt32(at: 16, value: stop ? 1 : 0)
    }

    // MARK: - Audio data pointer

    private var audioDataPtr: UnsafeMutablePointer<Float> {
        (mappedData + Self.headerSize).assumingMemoryBound(to: Float.self)
    }

    // MARK: - Producer (Extension)

    /// Write audio samples to the ring buffer. Called from the extension.
    func write(_ samples: [Float]) {
        guard isProducer else { return }

        var writePos = Int(writeOffset)
        let capacity = Self.capacity
        let ptr = audioDataPtr

        for sample in samples {
            ptr[writePos] = sample
            writePos = (writePos + 1) % capacity
        }

        // Store write offset atomically after all samples are written
        writeOffset = UInt32(writePos)
    }

    // MARK: - Consumer (Main App)

    /// Read all available audio samples from the ring buffer. Called from the main app.
    /// Returns an empty array if no new data is available.
    func readAvailable() -> [Float] {
        guard !isProducer else { return [] }

        let writePos = Int(writeOffset)
        var readPos = Int(readOffset)
        let capacity = Self.capacity
        let ptr = audioDataPtr

        guard readPos != writePos else { return [] }

        var samples: [Float] = []
        // Calculate available count
        let available: Int
        if writePos >= readPos {
            available = writePos - readPos
        } else {
            available = capacity - readPos + writePos
        }
        samples.reserveCapacity(available)

        while readPos != writePos {
            samples.append(ptr[readPos])
            readPos = (readPos + 1) % capacity
        }

        // Update read offset
        readOffset = UInt32(readPos)

        return samples
    }
}
