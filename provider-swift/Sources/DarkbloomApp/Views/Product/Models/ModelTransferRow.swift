import SwiftUI

struct ModelTransferRow: View {
    let model: ModelSummary
    let onPause: () -> Void
    let onResume: () -> Void

    private var progress: ModelTransferProgress? { model.installation.progress }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.displayName)
                    Spacer(minLength: 0)
                    Text(progress?.fractionComplete.formatted(.percent.precision(.fractionLength(0))) ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.accent)
                        .monospacedDigit()
                }
                ProgressView(value: progress?.fractionComplete ?? 0)
                    .tint(StudioPalette.accent)
                    .accessibilityLabel("Download progress for \(model.displayName)")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(transferStateTitle)
                        Spacer(minLength: 0)
                        Text(transferDetail)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transferStateTitle)
                        Text(transferDetail)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.secondaryInk)
                .monospacedDigit()
                if let eta = progress?.estimatedSecondsRemaining, eta > 0,
                   case .downloading = model.installation {
                    Text("About \(eta)s remaining")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.secondaryInk)
                }
            }
            switch model.installation {
            case .downloading:
                Button("Pause", systemImage: "pause.fill", action: onPause)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Pause download of \(model.displayName)")
            case .paused:
                Button("Resume", systemImage: "play.fill", action: onResume)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Resume download of \(model.displayName)")
            case .verifying:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Verifying \(model.displayName)")
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private var transferStateTitle: String {
        switch model.installation {
        case .downloading(let progress):
            progress.isResumed ? "Resuming download" : "Downloading"
        case .paused:
            "Paused. Progress is saved."
        case .verifying:
            "Verifying model weights"
        default:
            "Preparing"
        }
    }

    private var transferDetail: String {
        guard let progress else { return "" }
        let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        if case .downloading = model.installation, progress.bytesPerSecond > 0 {
            let speed = ByteCountFormatter.string(fromByteCount: progress.bytesPerSecond, countStyle: .file)
            return "\(downloaded) of \(total), \(speed)/s"
        }
        return "\(downloaded) of \(total)"
    }
}
