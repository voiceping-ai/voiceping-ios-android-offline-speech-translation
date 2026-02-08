import SwiftUI

struct AudioVisualizerView: View {
    let energyLevels: [Float]

    private let barCount = 50

    private var displayLevels: [Float] {
        guard !energyLevels.isEmpty else {
            return Array(repeating: 0, count: barCount)
        }
        let suffix = Array(energyLevels.suffix(barCount))
        let padding = Array(repeating: Float(0), count: max(0, barCount - suffix.count))
        return suffix + padding
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level > 0.3 ? Color.blue : Color.blue.opacity(0.3))
                        .frame(
                            width: max(
                                2,
                                (geometry.size.width - CGFloat(barCount) * 2)
                                    / CGFloat(barCount)
                            ),
                            height: max(4, CGFloat(level) * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("audio_visualizer")
    }
}
