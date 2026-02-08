import Foundation
#if canImport(Translation)
import Translation
#endif

@MainActor
final class AppleTranslationService {
    /// Type-erased storage for TranslationSession (avoids requiring Translation import in callers).
    private var _session: Any?

    /// Whether a translation session is currently available.
    var hasSession: Bool { _session != nil }

    /// Store the session obtained from SwiftUI's `.translationTask()` modifier.
    func setSession(_ session: Any?) {
        _session = session
    }

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        if sourceLanguageCode == targetLanguageCode {
            return normalized
        }

        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            guard let session = _session as? TranslationSession else {
                throw AppError.translationUnavailable
            }
            let response = try await session.translate(normalized)
            return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw AppError.translationUnavailable
        }
        #else
        throw AppError.translationUnavailable
        #endif
    }
}
