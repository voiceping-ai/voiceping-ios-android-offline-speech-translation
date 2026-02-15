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

    /// Tracks multi-file download progress. Protected by progressLock for
    /// thread-safe reads from URLSession delegate callbacks.
    private let progressLock = NSLock()
    nonisolated(unsafe) private var _currentFileIndex: Int = 0
    nonisolated(unsafe) private var _totalFilesToDownload: Int = 1

    private nonisolated var currentFileIndex: Int {
        get { progressLock.withLock { _currentFileIndex } }
        set { progressLock.withLock { _currentFileIndex = newValue } }
    }
    private nonisolated var totalFilesToDownload: Int {
        get { progressLock.withLock { _totalFilesToDownload } }
        set { progressLock.withLock { _totalFilesToDownload = newValue } }
    }

    private static let huggingFaceOrg = "csukuangfj"
    nonisolated(unsafe) private static let fileManager = FileManager.default
    private static let downloadSessionConfiguration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 45 * 60
        config.waitsForConnectivity = true
        return config
    }()

    /// Directory where model files are stored.
    static var modelsDirectory: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable")
        }
        return appSupport.appendingPathComponent("SherpaModels", isDirectory: true)
    }

    /// Check if all required model files are already downloaded.
    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        guard let config = model.sherpaModelConfig else { return false }
        let modelDir = Self.modelsDirectory.appendingPathComponent(config.repoName)
        return config.allFiles.allSatisfy { file in
            Self.fileManager.fileExists(atPath: modelDir.appendingPathComponent(file).path)
        }
    }

    /// Get the local directory path for a downloaded model.
    func modelDirectory(for model: ModelInfo) -> URL? {
        guard let config = model.sherpaModelConfig else { return nil }
        let dir = Self.modelsDirectory.appendingPathComponent(config.repoName)
        guard Self.fileManager.fileExists(atPath: dir.path) else { return nil }
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
        progress = 0

        if isModelDownloaded(model) {
            progress = 1
            return modelDir
        }

        // Create model directory
        try Self.fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Determine which files still need downloading
        let filesToDownload = config.allFiles.filter { filename in
            !Self.fileManager.fileExists(atPath: modelDir.appendingPathComponent(filename).path)
        }

        guard !filesToDownload.isEmpty else { return modelDir }

        totalFilesToDownload = filesToDownload.count

        for (index, filename) in filesToDownload.enumerated() {
            currentFileIndex = index

            let url = try Self.fileURL(repo: config.repoName, filename: filename)
            let tempFile = try await downloadFile(from: url)

            let destPath = modelDir.appendingPathComponent(filename)
            // Remove partial file if it exists
            try? Self.fileManager.removeItem(at: destPath)
            try Self.fileManager.moveItem(at: tempFile, to: destPath)
        }

        guard isModelDownloaded(model) else {
            throw AppError.modelDownloadFailed(underlying: NSError(
                domain: "ModelDownloader", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded files but model validation failed"]
            ))
        }

        progress = 1
        return modelDir
    }

    /// Delete a downloaded model.
    func deleteModel(_ model: ModelInfo) throws {
        guard let config = model.sherpaModelConfig else { return }
        let modelDir = Self.modelsDirectory.appendingPathComponent(config.repoName)
        if Self.fileManager.fileExists(atPath: modelDir.path) {
            try Self.fileManager.removeItem(at: modelDir)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil

        // Resume continuation BEFORE invalidating session, so that
        // delegate callbacks from invalidation don't race with the caller.
        resumeContinuation(with: .failure(CancellationError()))

        session?.invalidateAndCancel()
        session = nil
    }

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: - Private

    private static func fileURL(repo: String, filename: String) throws -> URL {
        guard let url = URL(string: "https://huggingface.co/\(huggingFaceOrg)/\(repo)/resolve/main/\(filename)") else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid HuggingFace URL for \(repo)/\(filename)"])
        }
        return url
    }

    private func downloadFile(from url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(
                configuration: Self.downloadSessionConfiguration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session

            continuationLock.lock()
            self.continuation = continuation
            continuationLock.unlock()

            self.downloadTask = session.downloadTask(with: url)
            self.downloadTask?.resume()
        }
    }

    private nonisolated func resumeContinuation(with result: Result<URL, Error>) {
        continuationLock.lock()
        let cont = continuation
        continuation = nil
        continuationLock.unlock()
        switch result {
        case .success(let url):
            cont?.resume(returning: url)
        case .failure(let error):
            cont?.resume(throwing: error)
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
        let tempDir = Self.fileManager.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)

        do {
            try Self.fileManager.copyItem(at: location, to: tempFile)
            session.finishTasksAndInvalidate()
            resumeContinuation(with: .success(tempFile))
        } catch {
            session.finishTasksAndInvalidate()
            resumeContinuation(with: .failure(error))
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
        resumeContinuation(with: .failure(error))
    }
}
