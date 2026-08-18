import SwiftUI

struct MyMacsInventoryList: View {
    let macs: [MyMac]
    let fleet: [MyMac]
    let currentSerialNumber: String?
    @Binding var selection: String?
    @Binding var searchText: String
    @Binding var statusFilter: MyMacsStatusFilter
    @Binding var attentionFilter: MyMacsAttentionFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProductSectionHeader("Macs", detail: "\(macs.count) shown")

            filterBar

            if macs.isEmpty {
                ContentUnavailableView {
                    Label("No matching Macs", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Try a different search or clear one of the filters.")
                } actions: {
                    Button("Clear Filters", action: clearFilters)
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            } else {
                List(macs, selection: $selection) { mac in
                    MyMacInventoryRow(
                        mac: mac,
                        displayTitle: MyMacsPresentation.title(for: mac, in: fleet),
                        isThisMac: MyMacsPresentation.isThisMac(
                            mac,
                            currentSerialNumber: currentSerialNumber
                        )
                    )
                    .tag(mac.id)
                }
                .listStyle(.inset)
                .frame(minHeight: 260, idealHeight: 340, maxHeight: .infinity)
                .accessibilityLabel("Mac inventory")
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Macs", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search Macs")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(ProductPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ProductPalette.stroke, lineWidth: 1)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusPicker
                    attentionPicker
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 230)

                VStack(alignment: .leading, spacing: 6) {
                    statusPicker
                    attentionPicker
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusPicker: some View {
        Picker("Status", selection: $statusFilter) {
            ForEach(MyMacsStatusFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
        .help("Filter by connection status")
    }

    private var attentionPicker: some View {
        Picker("Attention", selection: $attentionFilter) {
            ForEach(MyMacsAttentionFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
        .help("Filter by coordinator attention")
    }

    private func clearFilters() {
        searchText = ""
        statusFilter = .all
        attentionFilter = .all
    }
}

private struct MyMacInventoryRow: View {
    let mac: MyMac
    let displayTitle: String
    let isThisMac: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                titleLine

                Text(MyMacsPresentation.inventorySupportLine(for: mac))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: MyMacsPresentation.lifecycleSymbol(mac.lifecycle))
                        .font(.caption2.weight(.semibold))
                    Text(MyMacsPresentation.lifecycleTitle(mac.lifecycle))
                        .font(.caption2.weight(.medium))

                    if mac.attention.requiresAttention {
                        Text("·")
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                        Text("Needs attention")
                            .font(.caption2.weight(.medium))
                    }
                }
                .foregroundStyle(statusTint)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleLine: some View {
        if isThisMac {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    title
                    thisMacBadge
                }

                VStack(alignment: .leading, spacing: 1) {
                    title
                    thisMacBadge
                }
            }
        } else {
            title
        }
    }

    private var title: some View {
        Text(displayTitle)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
    }

    private var thisMacBadge: some View {
        Text("THIS MAC")
            .font(.caption2.weight(.bold))
            .tracking(0.55)
            .foregroundStyle(DarkbloomTheme.accent)
            .fixedSize()
    }

    private var symbol: String {
        MacFormFactor.classify(
            displayName: mac.hardware?.machineModel ?? "Mac",
            modelIdentifier: ""
        ).symbolName
    }

    private var statusTint: Color {
        if mac.attention.requiresAttention {
            return ProductPalette.warning
        }
        switch mac.lifecycle {
        case .serving:
            return DarkbloomTheme.accent
        case .online:
            return ProductPalette.positive
        case .untrusted:
            return ProductPalette.critical
        case .offline, .neverSeen, .unknown:
            return Color.secondary
        }
    }
}
