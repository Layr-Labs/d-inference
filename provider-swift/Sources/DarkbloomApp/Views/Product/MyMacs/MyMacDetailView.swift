import SwiftUI

struct MyMacDetailView: View {
    let mac: MyMac
    let fleet: [MyMac]
    let isThisMac: Bool
    let serialIsRevealed: Bool
    let serialWasCopied: Bool
    let onToggleSerial: () -> Void
    let onCopySerial: () -> Void
    let onOpenHardware: () -> Void
    let onOpenActivity: () -> Void
    let onOpenModels: () -> Void
    let onRunSystemCheck: () -> Void
    let onRequestRemoval: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isThisMac {
                localActions
            }

            Divider()
            MyMacLatestReportSection(mac: mac)
            Divider()
            MyMacHardwareSection(
                mac: mac,
                serialIsRevealed: serialIsRevealed,
                serialWasCopied: serialWasCopied,
                onToggleSerial: onToggleSerial,
                onCopySerial: onCopySerial
            )
            Divider()
            MyMacModelsSection(mac: mac)
            Divider()
            MyMacVerificationSection(mac: mac)
            Divider()
            MyMacLifetimeActivitySection(mac: mac)
            Divider()
            MyMacTechnicalDetails(mac: mac)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 52, height: 52)
                .background(DarkbloomTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(MyMacsPresentation.title(for: mac, in: fleet))
                        .font(DarkbloomTheme.chivo(21, weight: .medium))
                        .tracking(-0.35)
                        .accessibilityAddTraits(.isHeader)

                    if isThisMac {
                        Text("THIS MAC")
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(DarkbloomTheme.accent)
                    }
                }

                Text(MyMacsPresentation.supportLine(for: mac))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(MyMacsPresentation.lifecycleDetail(mac))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                MyMacStatusBadge(mac: mac)

                if mac.canRemove {
                    Menu {
                        Button(
                            "\(MyMacRemovalPresentation.actionTitle)…",
                            role: .destructive
                        ) {
                            onRequestRemoval()
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                            .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More actions for this retained Mac")
                    .accessibilityLabel(
                        "More actions for \(MyMacsPresentation.title(for: mac, in: fleet))"
                    )
                }
            }
        }
    }

    private var localActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button("Hardware", systemImage: "desktopcomputer", action: onOpenHardware)
                Button("Activity", systemImage: "waveform.path.ecg", action: onOpenActivity)
                Button("Models", systemImage: "shippingbox", action: onOpenModels)
                Button("System Check", systemImage: "stethoscope", action: onRunSystemCheck)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minWidth: 460, alignment: .leading)

            Menu("Open This Mac", systemImage: "macbook") {
                Button("Hardware", systemImage: "desktopcomputer", action: onOpenHardware)
                Button("Activity", systemImage: "waveform.path.ecg", action: onOpenActivity)
                Button("Models", systemImage: "shippingbox", action: onOpenModels)
                Divider()
                Button("Run System Check…", systemImage: "stethoscope", action: onRunSystemCheck)
            }
            .menuStyle(.borderlessButton)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        MacFormFactor.classify(
            displayName: mac.hardware?.machineModel ?? "Mac",
            modelIdentifier: ""
        ).symbolName
    }
}
