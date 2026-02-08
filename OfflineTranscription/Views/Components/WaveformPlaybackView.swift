import SwiftUI

struct WaveformPlaybackView: View {
    @State private var playerVM: AudioPlayerViewModel

    init(audioURL: URL) {
        _playerVM = State(initialValue: AudioPlayerViewModel(audioURL: audioURL))
    }

    var body: some View {
        VStack(spacing: 8) {
            waveformCanvas
            controlsRow
        }
    }

    // MARK: - Waveform Canvas

    private var waveformCanvas: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                waveformBars(in: geometry)
                scrubberLine(in: geometry)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, Double(value.location.x / geometry.size.width)))
                        playerVM.seek(to: fraction)
                    }
            )
        }
    }

    private func waveformBars(in geometry: GeometryProxy) -> some View {
        let playedFraction = playerVM.duration > 0
            ? playerVM.currentTime / playerVM.duration
            : 0

        return HStack(spacing: 1) {
            ForEach(Array(playerVM.waveformBars.enumerated()), id: \.offset) { index, level in
                let barFraction = Double(index) / Double(max(1, playerVM.waveformBars.count - 1))
                RoundedRectangle(cornerRadius: 1)
                    .fill(barFraction <= playedFraction ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(height: max(2, CGFloat(level) * geometry.size.height))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func scrubberLine(in geometry: GeometryProxy) -> some View {
        let progress = playerVM.duration > 0
            ? playerVM.currentTime / playerVM.duration
            : 0
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: geometry.size.height)
            .offset(x: CGFloat(progress) * geometry.size.width)
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack {
            Button {
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .accessibilityIdentifier("play_pause_button")

            Text(FormatUtils.formatDuration(playerVM.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Text(FormatUtils.formatDuration(playerVM.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
