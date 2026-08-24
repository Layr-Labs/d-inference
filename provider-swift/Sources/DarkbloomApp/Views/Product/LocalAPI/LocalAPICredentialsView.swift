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
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalAPIPresentation.apiKeyLabel(isLive: isLive).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    if isRevealed {
                        Text(endpoint.apiKey ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .accessibilityHidden(true)
                    } else {
                        Text("••••••••••••••••••••••••")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LocalAPIPresentation.apiKeyLabel(isLive: isLive))
                .accessibilityValue(isRevealed ? "Revealed" : "Hidden")

                HStack(spacing: 12) {
                    Button(isRevealed ? "Hide" : (isLive ? "Reveal key" : "Reveal sample key")) {
                        onReveal(!isRevealed)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        isRevealed
                            ? "Hide \(LocalAPIPresentation.apiKeyLabel(isLive: isLive))"
                            : "Reveal \(LocalAPIPresentation.apiKeyLabel(isLive: isLive))"
                    )

                    Button {
                        onCopy(.apiKey)
                    } label: {
                        Label(
                            copiedItem == .apiKey
                                ? "Copied"
                                : (isLive ? "Copy key" : "Copy sample key"),
                            systemImage: copiedItem == .apiKey ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy \(LocalAPIPresentation.apiKeyLabel(isLive: isLive))")

                    Spacer(minLength: 0)
                }

                Text(LocalAPIPresentation.credentialsDetail(isLive: isLive))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Authentication is disabled")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Any process that can reach this address can send inference requests.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ProductPalette.warning)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
