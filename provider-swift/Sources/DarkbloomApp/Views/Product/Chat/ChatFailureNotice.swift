import SwiftUI

struct ChatFailureNotice: View {
    let failure: ChatFailure
    let onRetry: (() -> Void)?
    let onCheckConnection: (() -> Void)?
    let onOpenLocalAPI: (() -> Void)?
    let onOpenModels: (() -> Void)?
    let onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(ProductPalette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(failure.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let onDismiss {
                    Button(action: onDismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss chat error")
                        .accessibilityLabel("Dismiss chat error")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: 780, alignment: .leading)
        .background(ProductPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(ProductPalette.stroke) }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        if let onRetry {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .help("Retry the failed turn without adding your message again")
        }
        if failure.recovery == .models, let onOpenModels {
            Button("Open Models", action: onOpenModels).buttonStyle(.bordered)
        } else if let onOpenLocalAPI, failure.recovery != nil {
            Button("Open Local API", action: onOpenLocalAPI).buttonStyle(.bordered)
        }
        if let onCheckConnection {
            Button("Check Connection", action: onCheckConnection).buttonStyle(.bordered)
        }
    }
}
