import SwiftUI

struct MyMacsInventoryList: View {
    let macs: [MyMac]
    let fleet: [MyMac]
    let isCompact: Bool
    @Binding var selection: String?
    @Binding var searchText: String
    @Binding var statusFilter: MyMacsStatusFilter
    @Binding var attentionFilter: MyMacsAttentionFilter
    let onOpenMac: (String) -> Void

    var body: some View {
        let titles = MyMacsPresentation.titles(in: fleet)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Macs").font(.headline)
                Spacer()
                Text("\(macs.count) of \(fleet.count)")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            filterBar
            if macs.isEmpty {
                ScrollView {
                    ContentUnavailableView {
                        Label("No matching Macs", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try another search or clear your filters.")
                    } actions: {
                        Button("Clear Filters", action: clearFilters)
                    }
                }
            } else if isCompact {
                List(macs) { mac in
                    Button { onOpenMac(mac.id) } label: {
                        HStack(spacing: 12) {
                            row(mac, titles: titles)
                            Image(systemName: "chevron.right")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open the latest report for this Mac")
                }
                .listStyle(.inset)
                .accessibilityLabel("Mac inventory")
            } else {
                List(macs, selection: $selection) { mac in
                    row(mac, titles: titles).tag(mac.id)
                }
                .listStyle(.inset)
                .accessibilityLabel("Mac inventory")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ mac: MyMac, titles: [String: String]) -> some View {
        MyMacInventoryRow(mac: mac, title: titles[mac.id] ?? MyMacsPresentation.title(for: mac))
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Macs or models", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search Macs or models")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(ProductPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).stroke(ProductPalette.stroke, lineWidth: 1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    statusPicker.fixedSize()
                    Spacer(minLength: 0)
                    attentionToggle.fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    statusPicker
                    attentionToggle
                }
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
        .accessibilityLabel("Filter Macs by status")
    }

    private var attentionToggle: some View {
        Toggle("Needs attention", isOn: Binding(
            get: { attentionFilter == .needsAttention },
            set: { attentionFilter = $0 ? .needsAttention : .all }
        ))
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func clearFilters() {
        searchText = ""
        statusFilter = .all
        attentionFilter = .all
    }
}

private struct MyMacInventoryRow: View {
    let mac: MyMac
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MacFormFactor.classify(
                displayName: mac.hardware?.machineModel ?? "Mac", modelIdentifier: ""
            ).symbolName)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(MyMacsPresentation.lifecycleTitle(mac.lifecycle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if mac.attention.requiresAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(ProductPalette.warning)
                    .help("Needs attention")
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .help("\(title) · \(MyMacsPresentation.lifecycleTitle(mac.lifecycle))")
        .accessibilityElement(children: .combine)
    }
}
