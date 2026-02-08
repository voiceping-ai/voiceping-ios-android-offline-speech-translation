import SwiftUI

struct TranscriptionBubble: View {
    let text: String
    let isConfirmed: Bool
    let timestamp: String?

    init(text: String, isConfirmed: Bool, timestamp: String? = nil) {
        self.text = text
        self.isConfirmed = isConfirmed
        self.timestamp = timestamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let timestamp = timestamp {
                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.body)
                .foregroundStyle(isConfirmed ? .primary : .secondary)
                .italic(!isConfirmed)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isConfirmed
                                ? Color(.systemBackground)
                                : Color(.secondarySystemBackground)
                        )
                )
        }
    }
}
