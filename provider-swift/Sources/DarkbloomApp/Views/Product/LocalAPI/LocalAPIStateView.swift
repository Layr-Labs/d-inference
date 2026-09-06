import SwiftUI

struct LocalAPIStateView: View {
    typealias Kind = LocalAPIEndpointPhase

    let kind: Kind
    let message: String
    let isLive: Bool
    let onRetry: () -> Void
    let onOpenDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DarkbloomTheme.chivo(19, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if kind == .starting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(isLive ? "Checking the endpoint" : "Checking the sample endpoint")
                }
            }

            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if kind == .unavailable {
                HStack(spacing: 14) {
                    Button("Check again", action: onRetry)
                        .buttonStyle(StudioPrimaryButtonStyle())
                    Button("Diagnostics", action: onOpenDiagnostics)
                }
                .padding(.top, 4)
            }

            DisclosureGroup("Connection details") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .textSelection(.enabled)
                    if kind == .unavailable {
                        Text("Check that the port is free, ~/.darkbloom is writable, and the provider process is running. Darkbloom checks process identity and HTTP responses separately.")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            .font(.system(size: 12))
            .padding(.top, 3)
        }
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
        if kind == .starting {
            return isLive ? "Checking endpoint" : "Checking sample endpoint"
        }
        return LocalAPIPresentation.stateTitle(kind, isLive: isLive)
    }

    private var summary: String {
        switch kind {
        case .starting: "Connection details appear after the endpoint responds."
        case .stopped: isLive ? "Start a model to connect your tools." : "This sample has no running endpoint."
        case .unavailable: "The connection could not be verified."
        }
    }

    private var systemImage: String {
        switch kind {
        case .starting: "arrow.triangle.2.circlepath"
        case .stopped: "power"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch kind {
        case .starting: StudioPalette.accent
        case .stopped: StudioPalette.secondaryInk
        case .unavailable: ProductPalette.warning
        }
    }
}
