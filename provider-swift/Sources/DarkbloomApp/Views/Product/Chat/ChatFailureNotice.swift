import SwiftUI

/// Inline, actionable error surface for live chat sends. Renders between the
/// conversation and the composer: what happened, what to do (start the
/// provider from the Overview), and how to recover (retry / dismiss).
struct ChatFailureNotice: View {
    let failure: ChatFailure
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 13))
                .foregroundStyle(ProductPalette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(failure.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let onRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss chat error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 720)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ProductPalette.elevatedSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ProductPalette.stroke, lineWidth: 1)
                }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
