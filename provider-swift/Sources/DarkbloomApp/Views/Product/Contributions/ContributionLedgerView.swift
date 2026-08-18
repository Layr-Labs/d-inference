import SwiftUI

struct ContributionLedgerView: View {
    let store: ContributionsStore
    let asOf: Date

    private var records: [ContributionRecord] { store.filteredLedger }
    private var scope: ContributionScope { store.scope }

    var body: some View {
        @Bindable var bindableStore = store

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent private work")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Label("No prompt or response content is stored", systemImage: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Machines", selection: $bindableStore.scope) {
                    ForEach(ContributionScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            if records.isEmpty {
                emptyState
                    .padding(.top, 12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        ContributionLedgerRow(record: record, scope: scope, asOf: asOf)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 13)

                        if index < records.count - 1 {
                            Divider()
                                .padding(.leading, 53)
                        }
                    }
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "leaf")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 42, height: 42)
                .background(DarkbloomTheme.accent.opacity(0.09), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(scope == .thisMac ? "No completed work from this Mac yet" : "No completed work yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("When private network work completes, its accounting record will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(18)
        .productSurface()
    }
}

private struct ContributionLedgerRow: View {
    let record: ContributionRecord
    let scope: ContributionScope
    let asOf: Date

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DarkbloomTheme.accent.opacity(0.085))
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DarkbloomTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(record.modelName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if scope == .allMacs {
                        Text(record.providerName)
                        Text("·")
                    }
                    Text(ContributionsPresentation.ledgerDate(record.timestamp, relativeTo: asOf))
                    Text("·")
                    Text("\(ContributionsPresentation.tokenCount(record.totalTokens)) tokens")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(ContributionsPresentation.amount(record.amount))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.modelName)
        .accessibilityValue(
            [
                scope == .allMacs ? record.providerName : nil,
                ContributionsPresentation.ledgerDate(record.timestamp, relativeTo: asOf),
                "\(record.totalTokens) tokens",
                ContributionsPresentation.amount(record.amount),
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }
}
