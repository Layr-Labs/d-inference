import AppKit
import SwiftUI

struct MachineOverviewView: View {
    let identity: MachineIdentity
    let trust: ProviderTrustSnapshot
    let onRunDiagnostics: () -> Void

    @State private var revealsSerialNumber = false

    private var hardwareMetrics: [(String, String, String)] {
        [
            ("Unified memory", MachineFactsFormatter.memory(identity.physicalMemoryBytes), "memorychip"),
            ("GPU", identity.gpuCoreCount.map { "\($0) cores" } ?? "—", "square.stack.3d.up"),
            ("CPU", identity.processorCoreCount.map { "\($0) cores" } ?? "—", "cpu"),
            (
                "Storage",
                MachineFactsFormatter.storageSummary(
                    total: identity.storageTotalBytes,
                    available: identity.storageAvailableBytes
                ),
                "internaldrive"
            ),
        ]
    }

    var body: some View {
        ProductPage {
            ProductPageHeader(
                eyebrow: "This Mac",
                title: identity.displayName,
                subtitle: "Your machine’s private inference identity, hardware, and trust posture."
            ) {
                Button("Run system check", systemImage: "stethoscope", action: onRunDiagnostics)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    hardwarePassport
                    trustPanel
                        .frame(width: 292)
                }

                VStack(spacing: 14) {
                    hardwarePassport
                    trustPanel
                }
            }
            .padding(.top, 26)

            ProductSectionHeader("Hardware", detail: "Detected on this Mac")
                .padding(.top, 28)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(hardwareMetrics, id: \.0) { metric in
                    HStack(spacing: 13) {
                        Image(systemName: metric.2)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DarkbloomTheme.accent)
                            .frame(width: 34, height: 34)
                            .background(DarkbloomTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.0)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(metric.1)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        Spacer()
                    }
                    .padding(15)
                    .productSurface()
                }
            }

            ProductSectionHeader("Identity")
                .padding(.top, 28)

            VStack(spacing: 0) {
                identityRow("Model", value: identity.modelIdentifier.isEmpty ? "—" : identity.modelIdentifier)
                Divider().padding(.leading, 16)
                identityRow("Model number", value: identity.modelNumber ?? "—")
                Divider().padding(.leading, 16)
                serialIdentityRow
            }
            .productSurface()
        }
        .navigationTitle(identity.displayName)
    }

    private var hardwarePassport: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("PRIVATE HARDWARE PASSPORT", systemImage: "person.text.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(DarkbloomTheme.accent)
                Spacer()
            }

            HStack(spacing: 20) {
                Image(systemName: identity.formFactor.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 76, weight: .ultraLight))
                    .foregroundStyle(.primary)
                    .frame(width: 124, height: 106)

                VStack(alignment: .leading, spacing: 6) {
                    Text(identity.chipName)
                        .font(DarkbloomTheme.chivo(24))
                        .tracking(-0.5)
                    Text(identity.inferenceFunFact)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .lineLimit(3)
                }
            }
            .padding(.top, 19)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .productSurface()
    }

    private var trustPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: trustIcon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 25))
                    .foregroundStyle(trustTint)
                Spacer()
                ProductStatusBadge(
                    title: trustBadgeTitle,
                    systemImage: trust.state == .verified ? "checkmark" : "exclamationmark",
                    tint: trustTint
                )
            }

            Text(trust.level)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 18)
            Text(trust.reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.top, 5)

            Spacer(minLength: 14)

            if let updatedAt = trust.updatedAt {
                Text("Last checked \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 7)
            }

            Button("Open system check", systemImage: "chevron.right") {
                onRunDiagnostics()
            }
            .buttonStyle(.link)
        }
        .padding(20)
        .frame(minHeight: 180, alignment: .topLeading)
        .productSurface()
    }

    private func identityRow(_ label: String, value: String, privacySensitive: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .privacySensitive(privacySensitive)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var serialIdentityRow: some View {
        HStack {
            Text("Serial number")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            if revealsSerialNumber {
                Text(displayedSerialNumber)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .privacySensitive()
                    .textSelection(.enabled)
            } else {
                Text(displayedSerialNumber)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .privacySensitive()
            }

            Spacer()

            if identity.serialNumber != nil {
                Button(revealsSerialNumber ? "Hide" : "Reveal") {
                    revealsSerialNumber.toggle()
                }
                .buttonStyle(.borderless)

                if revealsSerialNumber {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(identity.serialNumber ?? "", forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var displayedSerialNumber: String {
        guard let serialNumber = identity.serialNumber, !serialNumber.isEmpty else { return "—" }
        guard !revealsSerialNumber else { return serialNumber }
        return "••••••" + serialNumber.suffix(4)
    }

    private var trustTint: Color {
        switch trust.state {
        case .verified: ProductPalette.positive
        case .pending, .unknown: ProductPalette.warning
        case .failed: ProductPalette.critical
        }
    }

    private var trustIcon: String {
        switch trust.state {
        case .verified: "checkmark.shield.fill"
        case .pending: "clock.badge.exclamationmark.fill"
        case .failed: "xmark.shield.fill"
        case .unknown: "questionmark.diamond.fill"
        }
    }

    private var trustBadgeTitle: String {
        switch trust.state {
        case .verified: "Verified"
        case .pending: "Checking"
        case .failed: "Action required"
        case .unknown: "Unknown"
        }
    }
}
