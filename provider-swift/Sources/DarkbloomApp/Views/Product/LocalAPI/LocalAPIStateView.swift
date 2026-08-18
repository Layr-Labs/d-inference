import SwiftUI

struct LocalAPIStateView: View {
    enum Kind {
        case starting
        case stopped
        case unavailable
    }

    let kind: Kind
    let message: String
    let onRetry: () -> Void
    let onOpenDiagnostics: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 30) {
                LocalAPILoopbackFilament(mode: nil, isActive: false)
                    .frame(width: 238)

                Divider()

                statusDetails
            }
            .frame(minWidth: 650)

            VStack(alignment: .leading, spacing: 18) {
                LocalAPILoopbackFilament(mode: nil, isActive: false)
                    .frame(maxWidth: .infinity)

                Divider()

                statusDetails
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ProductPalette.elevatedSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(ProductPalette.stroke, lineWidth: 1)
                }
        }
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if kind == .starting {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 6)
                    .accessibilityLabel("Waiting for the sample endpoint")
            } else if kind == .unavailable {
                HStack(spacing: 10) {
                    Button("Check Again", action: onRetry)
                        .buttonStyle(.borderedProminent)
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch kind {
        case .starting: "Sample endpoint is starting"
        case .stopped: "No sample endpoint is running"
        case .unavailable: "The sample endpoint needs attention"
        }
    }

    private var systemImage: String {
        switch kind {
        case .starting: "ellipsis.circle"
        case .stopped: "power"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .starting: DarkbloomTheme.accent
        case .stopped: Color.secondary
        case .unavailable: ProductPalette.warning
        }
    }
}
