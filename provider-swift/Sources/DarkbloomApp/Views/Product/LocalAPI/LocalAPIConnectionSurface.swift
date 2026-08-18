import SwiftUI

struct LocalAPIConnectionSurface: View {
    let endpoint: LocalAPIEndpointSnapshot
    let isAPIKeyRevealed: Bool
    let copiedItem: LocalAPICopyItem?
    let onRevealAPIKey: (Bool) -> Void
    let onCopy: (LocalAPICopyItem) -> Void
    let onOpenModels: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                LocalAPILoopbackFilament(
                    mode: endpoint.mode,
                    isActive: endpoint.health == .reachable
                )
                .frame(width: 238)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        ProductStatusBadge(
                            title: statusTitle,
                            systemImage: statusSystemImage,
                            tint: statusTint
                        )

                        Text("PROVIDER \(endpoint.version)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.55)
                            .foregroundStyle(.tertiary)
                    }

                    Text("OpenAI-compatible base URL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 16)

                    HStack(spacing: 9) {
                        Text(endpoint.baseURL.absoluteString)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)

                        Button {
                            onCopy(.baseURL)
                        } label: {
                            Image(systemName: copiedItem == .baseURL ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(copiedItem == .baseURL ? "Copied" : "Copy base URL")
                        .accessibilityLabel(copiedItem == .baseURL ? "Base URL copied" : "Copy base URL")
                    }

                    HStack(spacing: 0) {
                        connectionFact(
                            label: endpoint.mode == nil ? "Mode" : "Sample mode",
                            value: LocalAPIPresentation.modeTitle(endpoint.mode)
                        )
                        Divider().frame(height: 32)
                        connectionFact(
                            label: "Access",
                            value: LocalAPIPresentation.accessTitle(endpoint.bindScope)
                        )
                        Divider().frame(height: 32)
                        connectionFact(
                            label: "Available",
                            value: LocalAPIPresentation.availableModelSummary(endpoint.modelCatalog)
                        )
                    }
                    .padding(.vertical, 14)

                    Divider()

                    LocalAPICredentialsView(
                        endpoint: endpoint,
                        isRevealed: isAPIKeyRevealed,
                        copiedItem: copiedItem,
                        onReveal: onRevealAPIKey,
                        onCopy: onCopy
                    )
                    .padding(.top, 14)

                    if case .available(let modelIDs) = endpoint.modelCatalog, modelIDs.isEmpty {
                        HStack(spacing: 10) {
                            emptyModelsLabel
                            Spacer()
                            Button("Open Models", action: onOpenModels)
                        }
                        .padding(.top, 14)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 1_200 : 720)

            compactLayout
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ProductPalette.elevatedSurface)
                .overlay {
                    LinearGradient(
                        colors: [
                            DarkbloomTheme.nodePale.opacity(0.16),
                            Color.clear,
                            DarkbloomTheme.accent.opacity(0.055),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(DarkbloomTheme.accent.opacity(0.14), lineWidth: 1)
                }
        }
        .shadow(color: DarkbloomTheme.accent.opacity(0.07), radius: 24, y: 12)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            LocalAPILoopbackFilament(
                mode: endpoint.mode,
                isActive: endpoint.health == .reachable
            )
            .frame(maxWidth: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ProductStatusBadge(
                        title: statusTitle,
                        systemImage: statusSystemImage,
                        tint: statusTint
                    )

                    Text("PROVIDER \(endpoint.version)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.55)
                        .foregroundStyle(.tertiary)
                }

                Text("OpenAI-compatible base URL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)

                Text(endpoint.baseURL.absoluteString)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onCopy(.baseURL)
                } label: {
                    Label(
                        copiedItem == .baseURL ? "Copied" : "Copy base URL",
                        systemImage: copiedItem == .baseURL ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderless)
                .help(copiedItem == .baseURL ? "Copied" : "Copy base URL")
                .accessibilityLabel(copiedItem == .baseURL ? "Base URL copied" : "Copy base URL")
                .padding(.top, 7)

                VStack(alignment: .leading, spacing: 11) {
                    connectionFact(
                        label: endpoint.mode == nil ? "Mode" : "Sample mode",
                        value: LocalAPIPresentation.modeTitle(endpoint.mode),
                        allowsWrapping: true
                    )
                    Divider()
                    connectionFact(
                        label: "Access",
                        value: LocalAPIPresentation.accessTitle(endpoint.bindScope),
                        allowsWrapping: true
                    )
                    Divider()
                    connectionFact(
                        label: "Available",
                        value: LocalAPIPresentation.availableModelSummary(endpoint.modelCatalog),
                        allowsWrapping: true
                    )
                }
                .padding(.vertical, 14)

                Divider()

                LocalAPICredentialsView(
                    endpoint: endpoint,
                    isRevealed: isAPIKeyRevealed,
                    copiedItem: copiedItem,
                    onReveal: onRevealAPIKey,
                    onCopy: onCopy
                )
                .padding(.top, 14)

                if case .available(let modelIDs) = endpoint.modelCatalog, modelIDs.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            emptyModelsLabel
                            Spacer()
                            Button("Open Models", action: onOpenModels)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            emptyModelsLabel
                            Button("Open Models", action: onOpenModels)
                        }
                    }
                    .padding(.top, 14)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusTitle: String {
        switch endpoint.health {
        case .checking: "Checking sample endpoint"
        case .reachable where endpoint.isOpenWithoutAuthentication:
            "Sample endpoint open"
        case .reachable:
            "Sample endpoint ready"
        case .unreachable: "Sample endpoint unavailable"
        }
    }

    private var statusSystemImage: String {
        switch endpoint.health {
        case .checking: "ellipsis.circle"
        case .reachable where endpoint.isOpenWithoutAuthentication:
            "exclamationmark.triangle.fill"
        case .reachable:
            "checkmark.circle.fill"
        case .unreachable: "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch endpoint.health {
        case .checking: DarkbloomTheme.accent
        case .reachable where endpoint.isOpenWithoutAuthentication:
            ProductPalette.warning
        case .reachable:
            ProductPalette.positive
        case .unreachable: ProductPalette.warning
        }
    }

    private var emptyModelsLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(ProductPalette.warning)
                .accessibilityHidden(true)
            Text("No compatible models are available for this endpoint.")
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectionFact(
        label: String,
        value: String,
        allowsWrapping: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(allowsWrapping ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
