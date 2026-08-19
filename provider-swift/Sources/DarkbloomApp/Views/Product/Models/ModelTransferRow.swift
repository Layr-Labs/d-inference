import SwiftUI

struct ModelTransferRow: View {
    let model: ModelSummary
    let onPause: () -> Void
    let onResume: () -> Void

    private var progress: ModelTransferProgress? { model.installation.progress }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if case .paused(let paused) = model.installation {
                        ProductStatusBadge(
                            title: "Resumable",
                            systemImage: "arrow.trianglehead.clockwise",
                            tint: .secondary
                        )
                        .accessibilityLabel("Download resumable from \(paused.fractionComplete.formatted(.percent.precision(.fractionLength(0))))")
                    }
                    Spacer()
                    Text(transferDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ProgressView(value: progress?.fractionComplete ?? 0)
                    .tint(DarkbloomTheme.accent)

                HStack {
                    Text(transferStateTitle)
                    Spacer()
                    if let eta = progress?.estimatedSecondsRemaining, eta > 0 {
                        Text("About \(eta)s remaining")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            switch model.installation {
            case .downloading:
                Button(action: onPause) { Image(systemName: "pause.fill") }
                    .buttonStyle(.borderless)
                    .help("Pause download")
            case .paused:
                Button(action: onResume) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Resume download")
            default:
                EmptyView()
            }
        }
    }

    private var transferStateTitle: String {
        switch model.installation {
        case .downloading(let progress):
            let base = progress.isResumed ? "Resuming download" : "Downloading"
            let percent = progress.fractionComplete.formatted(.percent.precision(.fractionLength(0)))
            return "\(base) — \(percent)"
        case .paused:
            return "Paused — progress is saved"
        case .verifying:
            return "Verifying model weights"
        default:
            return "Preparing"
        }
    }

    private var transferDetail: String {
        guard let progress else { return "" }
        let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        if progress.bytesPerSecond > 0 {
            let speed = ByteCountFormatter.string(fromByteCount: progress.bytesPerSecond, countStyle: .file)
            return "\(downloaded) of \(total) · \(speed)/s"
        }
        return "\(downloaded) of \(total)"
    }
}
