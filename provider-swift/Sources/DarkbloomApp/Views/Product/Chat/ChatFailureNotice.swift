import SwiftUI

struct ChatFailureNotice: View {
    let failure: ChatFailure
    let onRetry: (() -> Void)?
    let onCheckConnection: (() -> Void)?
    let onOpenLocalAPI: (() -> Void)?
    let onOpenModels: (() -> Void)?
    let onDismiss: (() -> Void)?
    var hasInlineStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(summary)
                    .font(DarkbloomTheme.chivo(13, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onDismiss {
                    Button(action: onDismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss chat error")
                        .accessibilityLabel("Dismiss chat error")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { actions }
                VStack(alignment: .leading, spacing: 10) { actions }
            }
            .font(DarkbloomTheme.chivo(12))
            .foregroundStyle(StudioPalette.accent)

            ChatLocalStartDetails(summary: "Details", detail: failure.title + "\n" + failure.detail)
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        if failure == .selectedModelUnavailable { return "Choose an available model above to continue." }
        if failure == .noModels { return "Choose a local model for this chat." }
        if failure == .noDiscovery { return "Start a local model to send your message." }
        if onRetry != nil { return "The reply couldn’t finish. You can try it again." }
        return "Your local connection needs attention. Your draft is still here."
    }

    @ViewBuilder
    private var actions: some View {
        if let onRetry {
            Button("Try again", action: onRetry)
                .buttonStyle(StudioPrimaryButtonStyle())
                .help("Retry the failed turn without adding your message again")
        }
        if failure.recovery == .models, let onOpenModels {
            Button("Open Library", action: onOpenModels).buttonStyle(.borderless)
        } else if let onOpenLocalAPI, failure.recovery != nil {
            Button(hasInlineStart ? "Diagnostics" : "Connection settings", action: onOpenLocalAPI)
                .buttonStyle(.borderless)
        }
        if let onCheckConnection {
            Button("Check connection", action: onCheckConnection).buttonStyle(.borderless)
        }
    }
}
