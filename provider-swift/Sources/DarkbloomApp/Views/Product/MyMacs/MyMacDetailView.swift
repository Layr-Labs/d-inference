import SwiftUI

struct MyMacDetailView: View {
    let mac: MyMac
    let fleet: [MyMac]
    let isRemoving: Bool
    let removalDisabled: Bool
    let onRequestRemoval: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            Divider()
            MyMacLatestReportSection(mac: mac)
            if mac.attention.requiresAttention {
                MyMacNoticeList(
                    items: mac.attention.coordinatorItems,
                    emptyText: "No attention items reported",
                    tint: ProductPalette.warning
                )
            }
            MyMacHardwareSection(mac: mac)
            disclosure("Reported models", systemImage: "shippingbox") {
                MyMacModelsSection(mac: mac)
            }
            disclosure("Verification and observations", systemImage: "checkmark.shield") {
                MyMacVerificationSection(mac: mac)
            }
            disclosure("Lifetime activity", systemImage: "chart.bar") {
                MyMacLifetimeActivitySection(mac: mac)
            }
            MyMacTechnicalDetails(mac: mac)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: MacFormFactor.classify(
                    displayName: mac.hardware?.machineModel ?? "Mac", modelIdentifier: ""
                ).symbolName)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(DarkbloomTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(DarkbloomTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(MyMacsPresentation.title(for: mac, in: fleet))
                        .font(DarkbloomTheme.chivo(22, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(MyMacsPresentation.supportLine(for: mac))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                MyMacStatusBadge(mac: mac)
                Spacer(minLength: 0)
                if isRemoving {
                    ProgressView().controlSize(.small)
                    Text("Removing…").font(.callout).foregroundStyle(.secondary)
                } else if mac.canRemove {
                    Menu {
                        Button("\(MyMacRemovalPresentation.actionTitle)…", role: .destructive, action: onRequestRemoval)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(removalDisabled)
                    .accessibilityLabel("Actions for \(MyMacsPresentation.title(for: mac, in: fleet))")
                }
            }
            Text(MyMacsPresentation.lifecycleDetail(mac))
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func disclosure<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup {
            content().padding(.top, 12)
        } label: {
            Label(title, systemImage: systemImage).font(.body.weight(.medium))
        }
    }
}
