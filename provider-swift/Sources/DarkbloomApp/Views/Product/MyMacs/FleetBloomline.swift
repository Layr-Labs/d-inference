import SwiftUI

/// A quiet account-membership map. The line means "linked to one account";
/// it intentionally carries no arrows, pulses, or traffic semantics.
struct FleetBloomline: View {
    let macs: [MyMac]
    let selectedID: String?
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LINKED TO ONE ACCOUNT")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(macs.count) \(macs.count == 1 ? "Mac" : "Macs")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ViewThatFits(in: .horizontal) {
                bloomNodes
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .trailing, spacing: 5) {
                    ScrollView(.horizontal) {
                        bloomNodes
                    }
                    .scrollIndicators(.visible)

                    Label("Scroll to see every linked Mac", systemImage: "arrow.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(ProductPalette.surface)
                        : AnyShapeStyle(.thinMaterial)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(ProductPalette.stroke, lineWidth: 1)
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: selectedID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(macs.count) Macs linked to this account")
        .accessibilityValue(
            selectedMacTitle.map { "Selected: \($0)" } ?? "No Mac selected"
        )
    }

    private var selectedMacTitle: String? {
        guard let selectedID,
              let selected = macs.first(where: { $0.id == selectedID })
        else { return nil }
        return MyMacsPresentation.title(for: selected, in: macs)
    }

    private var bloomNodes: some View {
        HStack(spacing: 0) {
            ForEach(Array(macs.enumerated()), id: \.element.id) { index, mac in
                BloomlineNode(
                    mac: mac,
                    title: MyMacsPresentation.bloomlineTitle(for: mac, in: macs),
                    fullTitle: MyMacsPresentation.title(for: mac, in: macs),
                    isSelected: selectedID == mac.id,
                    showsLeadingLine: index > 0,
                    showsTrailingLine: index < macs.count - 1,
                    reduceTransparency: reduceTransparency,
                    action: { onSelect(mac.id) }
                )
            }
        }
        .padding(.vertical, 3)
    }
}

private struct BloomlineNode: View {
    let mac: MyMac
    let title: String
    let fullTitle: String
    let isSelected: Bool
    let showsLeadingLine: Bool
    let showsTrailingLine: Bool
    let reduceTransparency: Bool
    let action: () -> Void

    private var symbol: String {
        MacFormFactor.classify(
            displayName: mac.hardware?.machineModel ?? "Mac",
            modelIdentifier: ""
        ).symbolName
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                HStack(spacing: 0) {
                    line.opacity(showsLeadingLine ? 1 : 0)

                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(DarkbloomTheme.accent.opacity(
                                    reduceTransparency ? 0.18 : 0.24
                                ))
                                .frame(width: 40, height: 40)
                                .blur(radius: reduceTransparency ? 0 : 7)
                        }

                        Circle()
                            .fill(isSelected ? DarkbloomTheme.accent : Color.secondary.opacity(0.22))
                            .frame(width: isSelected ? 12 : 8, height: isSelected ? 12 : 8)
                            .overlay {
                                Circle()
                                    .stroke(
                                        isSelected ? Color.primary.opacity(0.16) : .clear,
                                        lineWidth: 1
                                    )
                            }
                    }
                    .frame(width: 42, height: 42)

                    line.opacity(showsTrailingLine ? 1 : 0)
                }

                Label(title, systemImage: symbol)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 124)
            }
            .frame(width: 134)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fullTitle)
        .accessibilityLabel(fullTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Selects this Mac")
    }

    private var accessibilityValue: String {
        var values = [MyMacsPresentation.lifecycleTitle(mac.lifecycle)]
        if isSelected {
            values.append("Selected")
        }
        if mac.attention.requiresAttention {
            values.append("Needs attention")
        }
        return values.joined(separator: ", ")
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 46, height: 1)
    }
}
