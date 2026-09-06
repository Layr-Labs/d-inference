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
    let actionDisabled: Bool

    init(
        kind: Kind,
        message: String?,
        onRetry: (() -> Void)?,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        onAction: (() -> Void)? = nil,
        actionDisabled: Bool = false
    ) {
        self.kind = kind
        self.message = message
        self.onRetry = onRetry
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.onAction = onAction
        self.actionDisabled = actionDisabled
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
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

            case .signedOut:
                HStack(alignment: .center, spacing: 42) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 88, weight: .ultraLight))
                        .foregroundStyle(StudioPalette.accent)
                        .frame(width: 180, height: 200)
                        .background(StudioPalette.accentSoft, in: RoundedRectangle(cornerRadius: 28))
                    VStack(alignment: .leading, spacing: 18) {
                        Text("One place for\nevery Mac.")
                            .font(DarkbloomTheme.chivo(34))
                            .tracking(-1)
                            .accessibilityAddTraits(.isHeader)
                        Text(message ?? "Sign in to see your linked Macs, check their activity, and manage how they contribute to Darkbloom.")
                            .font(.system(size: 14))
                            .foregroundStyle(StudioPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 340, alignment: .leading)
                        primaryAction.buttonStyle(StudioPrimaryButtonStyle())
                        Text("Local AI in Studio works without network setup.")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioPalette.secondaryInk)
                    }
                    .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 44)

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
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let actionTitle, let onAction {
            if let actionSystemImage {
                Button(actionTitle, systemImage: actionSystemImage, action: onAction)
                    .disabled(actionDisabled)
            } else {
                Button(actionTitle, action: onAction)
                    .disabled(actionDisabled)
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
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
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
