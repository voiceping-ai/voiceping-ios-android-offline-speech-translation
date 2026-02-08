import Foundation

enum ZIPExporter {
    struct SessionBundle {
        let transcriptText: String
        let metadata: [String: Any]
        let audioFileURL: URL?
    }

    /// Create a ZIP file containing transcript.txt, metadata.json, and optionally audio.wav.
    /// Returns the URL of the temporary ZIP file.
    static func exportSession(_ bundle: SessionBundle) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write transcript.txt
        let transcriptURL = tempDir.appendingPathComponent("transcript.txt")
        try bundle.transcriptText.write(to: transcriptURL, atomically: true, encoding: .utf8)

        // Write metadata.json
        let metadataURL = tempDir.appendingPathComponent("metadata.json")
        let jsonData = try JSONSerialization.data(
            withJSONObject: bundle.metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: metadataURL, options: .atomic)

        // Copy audio.wav if present
        if let audioURL = bundle.audioFileURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            let destAudio = tempDir.appendingPathComponent("audio.wav")
            try FileManager.default.copyItem(at: audioURL, to: destAudio)
        }

        // Create ZIP using NSFileCoordinator (zero-dependency approach)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription_export.zip")
        try? FileManager.default.removeItem(at: zipURL)

        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: tempDir,
            options: .forUploading,
            error: &coordinatorError
        ) { zipTempURL in
            try? FileManager.default.copyItem(at: zipTempURL, to: zipURL)
        }

        // Clean up staging directory
        try? FileManager.default.removeItem(at: tempDir)

        if let error = coordinatorError {
            throw error
        }

        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw NSError(
                domain: "ZIPExporter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create ZIP archive"]
            )
        }

        return zipURL
    }
}
