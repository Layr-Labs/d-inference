import SwiftUI

struct HowItWorksSheet: View {
    let showsPreviewChrome: Bool
    let onStartSetup: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    overview
                    setupSteps
                }
                .padding(28)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .background(ProductPalette.pageBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How Darkbloom works")
                    .font(DarkbloomTheme.chivo(24))
                    .tracking(-0.4)
                Text("A network of Macs, and your own local studio.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Close", systemImage: "xmark") {
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var overview: some View {
        VStack(spacing: 12) {
            explanationRow(
                icon: "network",
                title: "Use AI across the network",
                detail: "Darkbloom connects AI apps with participating Apple silicon Macs. Use network models from the web console or an OpenAI-compatible client."
            )
            explanationRow(
                icon: "moon.stars.fill",
                title: "Contribute this Mac when you choose",
                detail: "Connect your account and verify this Mac to provide compute to the network. Choose an availability schedule, pause sharing, and review its contribution."
            )
            explanationRow(
                icon: "macbook",
                title: "Work locally in Studio",
                detail: "Studio runs an installed model on this Mac without network enrollment. Your local session and network sharing have separate controls."
            )
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect this Mac to the network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                setupRow(1, "Check compatibility", "Confirm Apple silicon, memory, storage, and macOS readiness.")
                Divider().padding(.leading, 46)
                setupRow(2, "Connect your account", "Approve this Mac in your browser and return to Darkbloom.")
                Divider().padding(.leading, 46)
                setupRow(3, "Install the verification profile", "macOS asks for administrator approval in System Settings. The profile verifies this Mac’s identity and security posture.")
                Divider().padding(.leading, 46)
                setupRow(4, "Prepare private AI", "Download a compatible model, start the local engine, and verify the provider.")
            }
            .productSurface()

            if showsPreviewChrome {
                Label(
                    "This UI preview simulates setup. It does not install a profile, download a model, or start a provider.",
                    systemImage: "eye.fill"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Not now") {
                dismiss()
            }

            Spacer()

            Button("Connect this Mac") {
                dismiss()
                onStartSetup()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func explanationRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 36, height: 36)
                .background(DarkbloomTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func setupRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(DarkbloomTheme.accent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
    }
}
