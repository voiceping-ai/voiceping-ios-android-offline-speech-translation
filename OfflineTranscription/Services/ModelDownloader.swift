import Foundation

/// Downloads individual sherpa-onnx model files from HuggingFace.
@MainActor
final class ModelDownloader: NSObject, @unchecked Sendable {
    private(set) var progress: Double = 0.0
    var onProgress: ((Double) -> Void)?

    private var downloadTask: URLSessionDownloadTask?
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var continuation: CheckedContinuation<URL, Error>?
    private let continuationLock = NSLock()

    /// Tracks multi-file download progress.
    nonisolated(unsafe) private var currentFileIndex: Int = 0
    nonisolated(unsafe) private var totalFilesToDownload: Int = 1

    private static let huggingFaceOrg = "csukuangfj"

    /// Directory where model files are stored.
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SherpaModels", isDirectory: true)
    }

    /// Check if all required model files are already downloaded.
    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        guard let config = model.sherpaModelConfig else { return false }
        let modelDir = Self.modelsDirectory.appendingPathComponent(config.repoName)
        for file in config.allFiles {
            if !FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(file).path) {
                return false
            }
        }
        return true
    }

    /// Get the local directory path for a downloaded model.
    func modelDirectory(for model: ModelInfo) -> URL? {
        guard let config = model.sherpaModelConfig else { return nil }
        let dir = Self.modelsDirectory.appendingPathComponent(config.repoName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir
    }

    /// Download all model files individually from HuggingFace. Returns the local model directory.
    func downloadModel(_ model: ModelInfo) async throws -> URL {
        guard let config = model.sherpaModelConfig else {
            throw AppError.modelDownloadFailed(underlying: NSError(
                domain: "ModelDownloader", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No sherpa model config for \(model.id)"]
            ))
        }

        let modelDir = Self.modelsDirectory.appendingPathComponent(config.repoName)

        if isModelDownloaded(model) {
            return modelDir
        }

        // Create model directory
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Determine which files still need downloading
        let filesToDownload = config.allFiles.filter { filename in
            !FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(filename).path)
        }

        guard !filesToDownload.isEmpty else { return modelDir }

        totalFilesToDownload = filesToDownload.count

        for (index, filename) in filesToDownload.enumerated() {
            currentFileIndex = index

            let url = Self.fileURL(repo: config.repoName, filename: filename)
            let tempFile = try await downloadFile(from: url)

            let destPath = modelDir.appendingPathComponent(filename)
            // Remove partial file if it exists
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: tempFile, to: destPath)
        }

        guard isModelDownloaded(model) else {
            throw AppError.modelDownloadFailed(underlying: NSError(
                domain: "ModelDownloader", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded files but model validation failed"]
            ))
        }

        return modelDir
    }

    /// Delete a downloaded model.
    func deleteModel(_ model: ModelInfo) throws {
        guard let config = model.sherpaModelConfig else { return }
        let modelDir = Self.modelsDirectory.appendingPathComponent(config.repoName)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil

        // Resume any waiting continuation so the caller doesn't hang
        continuationLock.lock()
        let cont = continuation
        continuation = nil
        continuationLock.unlock()
        cont?.resume(throwing: CancellationError())
    }

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: - Private

    private static func fileURL(repo: String, filename: String) -> URL {
        URL(string: "https://huggingface.co/\(huggingFaceOrg)/\(repo)/resolve/main/\(filename)")!
    }

    private func downloadFile(from url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session

            continuationLock.lock()
            self.continuation = continuation
            continuationLock.unlock()

            self.downloadTask = session.downloadTask(with: url)
            self.downloadTask?.resume()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)

        continuationLock.lock()
        let cont = continuation
        continuation = nil
        continuationLock.unlock()

        do {
            try FileManager.default.copyItem(at: location, to: tempFile)
            session.finishTasksAndInvalidate()
            cont?.resume(returning: tempFile)
        } catch {
            session.finishTasksAndInvalidate()
            cont?.resume(throwing: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fileFraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let total = Double(max(1, totalFilesToDownload))
        let overallFraction = (Double(currentFileIndex) + fileFraction) / total
        Task { @MainActor [weak self] in
            self?.progress = overallFraction
            self?.onProgress?(overallFraction)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        continuationLock.lock()
        let cont = continuation
        continuation = nil
        continuationLock.unlock()

        cont?.resume(throwing: error)
    }
}
