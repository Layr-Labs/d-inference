import SwiftUI

struct LocalAPICredentialsView: View {
    let endpoint: LocalAPIEndpointSnapshot
    let isLive: Bool
    let isRevealed: Bool
    let copiedItem: LocalAPICopyItem?
    let onReveal: (Bool) -> Void
    let onCopy: (LocalAPICopyItem) -> Void

    var body: some View {
        if endpoint.requiresAuthentication {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalAPIPresentation.apiKeyLabel(isLive: isLive))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        keyValue
                        Spacer(minLength: 0)
                        keyActions
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        keyValue
                        keyActions
                    }
                }

                DisclosureGroup("Key storage") {
                    Text(LocalAPIPresentation.credentialsDetail(isLive: isLive))
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.secondaryInk)
                .padding(.top, 3)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Authentication is disabled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioPalette.ink)
                    Text("Anyone who can reach this address can send requests.")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ProductPalette.warning)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var keyValue: some View {
        Group {
            if isRevealed {
                Text(endpoint.apiKey ?? "")
                    .textSelection(.enabled)
                    .accessibilityHidden(true)
            } else {
                Text("••••••••••••••••••••••••")
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(StudioPalette.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalAPIPresentation.apiKeyLabel(isLive: isLive))
        .accessibilityValue(isRevealed ? "Revealed" : "Hidden")
    }

    private var keyActions: some View {
        HStack(spacing: 15) {
            Button(isRevealed ? "Hide" : "Reveal") {
                onReveal(!isRevealed)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                isRevealed
                    ? "Hide \(LocalAPIPresentation.apiKeyLabel(isLive: isLive))"
                    : "Reveal \(LocalAPIPresentation.apiKeyLabel(isLive: isLive))"
            )

            LocalAPICopyButton(
                title: isLive ? "Copy key" : "Copy sample key",
                item: .apiKey, copiedItem: copiedItem, onCopy: onCopy
            )
            .accessibilityLabel("Copy \(LocalAPIPresentation.apiKeyLabel(isLive: isLive))")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(StudioPalette.accent)
        .fixedSize()
    }
}
