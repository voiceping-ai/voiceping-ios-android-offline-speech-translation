import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID
    var text: String
    var createdAt: Date
    var durationSeconds: Double
    var modelUsed: String
    var language: String?
    var audioFileName: String?

    init(
        text: String,
        durationSeconds: Double,
        modelUsed: String,
        language: String? = nil,
        audioFileName: String? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.durationSeconds = durationSeconds
        self.modelUsed = modelUsed
        self.language = language
        self.audioFileName = audioFileName
    }
}
