import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.blue)
                    .frame(width: 72, height: 72)
                    .shadow(
                        color: (isRecording ? Color.red : Color.blue).opacity(0.4),
                        radius: 8
                    )

                if isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .accessibilityIdentifier("record_button")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}
