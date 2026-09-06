import SwiftUI

struct MachineCardDetailsView: View {
    let identity: MachineIdentity

    private var siliconFacts: AppleSiliconFacts? {
        identity.siliconFacts
    }

    private var modelDescription: String {
        [identity.modelIdentifier, identity.modelNumber]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
            .ifEmpty("—")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(DarkbloomTheme.accent)
                    .frame(width: 7, height: 7)
                Text("PRIVATE HARDWARE PASSPORT")
                    .font(DarkbloomTheme.chivo(9, weight: .medium))
                    .tracking(0.95)
                Spacer()
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.4))
            }

            Text(identity.chipName)
                .font(DarkbloomTheme.chivo(21))
                .tracking(-0.35)
                .padding(.top, 13)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                MachineMetric(
                    label: "UNIFIED MEMORY",
                    value: MachineFactsFormatter.memory(identity.physicalMemoryBytes)
                )
                MachineMetric(
                    label: "STORAGE",
                    value: MachineFactsFormatter.storageSummary(
                        total: identity.storageTotalBytes,
                        available: identity.storageAvailableBytes
                    )
                )
                MachineMetric(
                    label: "CPU",
                    value: identity.processorCoreCount.map { "\($0) cores" } ?? "—"
                )
                MachineMetric(
                    label: "GPU",
                    value: identity.gpuCoreCount.map { "\($0) cores" } ?? "—"
                )
            }
            .padding(.top, 17)

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.1))
                .frame(height: 1)
                .padding(.vertical, 13)

            VStack(spacing: 7) {
                MachineIdentityRow(label: "MODEL", value: modelDescription)
                MachineIdentityRow(label: "SERIAL", value: identity.serialNumber ?? "—")
                MachineIdentityRow(
                    label: "SILICON ERA",
                    value: siliconFacts.map { "\($0.introductionYear) · M\($0.generation) generation" } ?? "—"
                )
            }

            Spacer(minLength: 10)

            Text(identity.inferenceFunFact)
                .font(DarkbloomTheme.chivo(10))
                .lineSpacing(2)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.52))
                .lineLimit(3)
        }
        .machineCardSurface(alignment: .leading)
    }
}

private struct MachineMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(DarkbloomTheme.chivo(8, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.46))
            Text(value)
                .font(DarkbloomTheme.chivo(14))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct MachineIdentityRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(DarkbloomTheme.chivo(8, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.42))
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(DarkbloomTheme.chivo(10))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
