import SwiftUI

struct MyMacsStateView: View {
    enum Kind {
        case loading
        case signedOut
        case empty
        case unavailable
    }

    let kind: Kind
    let message: String?
    let onRetry: (() -> Void)?
    let actionTitle: String?
    let actionSystemImage: String?
    let onAction: (() -> Void)?

    init(
        kind: Kind,
        message: String?,
        onRetry: (() -> Void)?,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.message = message
        self.onRetry = onRetry
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.onAction = onAction
    }

    var body: some View {
        Group {
            switch kind {
            case .loading:
                VStack(spacing: 13) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading linked Macs…")
                        .font(.system(size: 13, weight: .medium))
                    Text("Fetching the inventory for this Darkbloom account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .signedOut:
                ContentUnavailableView {
                    Label("Sign in to see your Macs", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("My Macs is account-scoped. Sign in to Darkbloom, then return here to see linked machines.")
                } actions: {
                    primaryAction
                }

            case .empty:
                ContentUnavailableView {
                    Label("No Macs linked yet", systemImage: "rectangle.3.group")
                } description: {
                    Text("Complete Darkbloom setup on a Mac to add it to this account.")
                } actions: {
                    primaryAction
                }

            case .unavailable:
                ContentUnavailableView {
                    Label("Mac inventory unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message ?? "Darkbloom could not load the Macs linked to this account.")
                } actions: {
                    if let onRetry {
                        Button("Try Again", action: onRetry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let actionTitle, let onAction {
            if let actionSystemImage {
                Button(actionTitle, systemImage: actionSystemImage, action: onAction)
            } else {
                Button(actionTitle, action: onAction)
            }
        }
    }
}

struct MyMacsBanner: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint = ProductPalette.warning

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.15), lineWidth: 1)
        }
    }
}
