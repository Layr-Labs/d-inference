import SwiftUI

struct LocalAPIConnectionSurface: View {
    let endpoint: LocalAPIEndpointSnapshot
    let isLive: Bool
    let isAPIKeyRevealed: Bool
    let copiedItem: LocalAPICopyItem?
    let onRevealAPIKey: (Bool) -> Void
    let onCopy: (LocalAPICopyItem) -> Void
    let onOpenModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connection")
                        .font(DarkbloomTheme.chivo(20, weight: .medium))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(LocalAPIPresentation.accessTitle(endpoint.bindScope)) · \(catalogSummary)")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Label(LocalAPIPresentation.healthTitle(endpoint, isLive: isLive), systemImage: statusSystemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusTint)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Base URL · OpenAI-compatible")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        baseURL
                        Spacer(minLength: 0)
                        copyURL
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        baseURL
                        copyURL
                    }
                }
            }

            Rectangle().fill(StudioPalette.line).frame(height: 1)

            LocalAPICredentialsView(
                endpoint: endpoint,
                isLive: isLive,
                isRevealed: isAPIKeyRevealed,
                copiedItem: copiedItem,
                onReveal: onRevealAPIKey,
                onCopy: onCopy
            )

            if case .available(let modelIDs) = endpoint.modelCatalog, modelIDs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No compatible models are listed by this endpoint.", systemImage: "shippingbox")
                        .font(.system(size: 12))
                        .foregroundStyle(ProductPalette.warning)
                    Button("Open Library", action: onOpenModels)
                        .buttonStyle(.borderless)
                }
            }
        }
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var baseURL: some View {
        Text(endpoint.baseURL.absoluteString)
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var copyURL: some View {
        LocalAPICopyButton(title: "Copy URL", item: .baseURL, copiedItem: copiedItem, onCopy: onCopy)
            .accessibilityLabel(copiedItem == .baseURL ? "Base URL copied" : "Copy base URL")
    }

    private var catalogSummary: String {
        switch endpoint.modelCatalog {
        case .loading: "Checking models…"
        case .failed: "Model list unavailable"
        case .available(let ids): ids.isEmpty ? "No models listed" : "\(ids.count) \(ids.count == 1 ? "model" : "models") listed"
        }
    }

    private var statusSystemImage: String {
        switch endpoint.health {
        case .checking: "ellipsis.circle"
        case .reachable where endpoint.isOpenWithoutAuthentication: "exclamationmark.triangle"
        case .reachable: "checkmark.circle"
        case .unreachable: "exclamationmark.triangle"
        }
    }

    private var statusTint: Color {
        switch endpoint.health {
        case .checking: StudioPalette.accent
        case .reachable where endpoint.isOpenWithoutAuthentication: ProductPalette.warning
        case .reachable: StudioPalette.accent
        case .unreachable: ProductPalette.warning
        }
    }
}
