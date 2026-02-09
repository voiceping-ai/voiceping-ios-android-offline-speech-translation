import SwiftUI

struct ModelPickerRow: View {
    let model: ModelInfo
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let isLoading: Bool
    let onTap: () -> Void

    init(
        model: ModelInfo,
        isSelected: Bool,
        isDownloaded: Bool,
        isDownloading: Bool = false,
        downloadProgress: Double = 0.0,
        isLoading: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.model = model
        self.isSelected = isSelected
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.downloadProgress = downloadProgress
        self.isLoading = isLoading
        self.onTap = onTap
    }

    private var clampedProgress: Double {
        min(max(downloadProgress, 0.0), 1.0)
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.displayName)
                            .font(.headline)
                        Text(model.parameterCount)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary)
                            .clipShape(Capsule())
                        if isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    Text(model.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Inference: \(model.inferenceMethodLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Size: \(model.sizeOnDisk)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if isDownloading {
                        ProgressView(value: clampedProgress)
                            .tint(.blue)
                            .padding(.top, 4)
                        Text("Downloading \(Int(clampedProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading model...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isSelected
                            ? Color.blue.opacity(0.08)
                            : Color(.secondarySystemBackground)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.blue.opacity(0.3) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
