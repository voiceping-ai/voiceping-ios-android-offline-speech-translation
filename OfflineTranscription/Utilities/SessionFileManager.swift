import Foundation

enum SessionFileManager {
    /// Base directory: Documents/sessions/
    static var sessionsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Directory for a specific session: Documents/sessions/{uuid}/
    static func sessionDirectory(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Full path to a session's audio file.
    static func audioFileURL(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("audio.wav")
    }

    /// Relative path stored in the data model: "sessions/{uuid}/audio.wav"
    static func relativeAudioPath(for id: UUID) -> String {
        "sessions/\(id.uuidString)/audio.wav"
    }

    /// Resolve a relative audioFileName to an absolute URL.
    static func resolveAudioURL(_ relativePath: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativePath)
    }

    /// Save audio samples as WAV for a given session UUID.
    static func saveAudio(samples: [Float], for id: UUID) throws {
        let dir = sessionDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try WAVWriter.write(samples: samples, to: audioFileURL(for: id))
    }

    /// Delete the session directory and all contents.
    static func deleteSession(for id: UUID) {
        let dir = sessionDirectory(for: id)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Check if audio file exists for a given session.
    static func audioFileExists(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioFileURL(for: id).path)
    }
}
