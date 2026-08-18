import SwiftUI

struct ContributionsView: View {
    let store: ContributionsStore
    let onReviewAvailability: () -> Void
    let onOpenDiagnostics: () -> Void

    @State private var showsPayout = false

    var body: some View {
        ProductPage {
            switch store.availability {
            case .available(let lastUpdated):
                if let snapshot = store.snapshot {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        availableContent(
                            snapshot: snapshot,
                            lastUpdated: lastUpdated,
                            now: context.date
                        )
                    }
                } else {
                    unavailableContent(message: "Account totals are not available yet.")
                }
            case .unavailable(let message):
                unavailableContent(message: message)
            }
        }
        .navigationTitle("Contributions")
        .sheet(isPresented: $showsPayout) {
            PreviewPayoutSheet(store: store)
        }
    }

    @ViewBuilder
    private func availableContent(
        snapshot: ContributionsSnapshot,
        lastUpdated: Date,
        now: Date
    ) -> some View {
        ProductPageHeader(
            eyebrow: "Network",
            title: "Useful work, accounted for.",
            subtitle: "See what your Macs contributed and earned. The ledger contains accounting metadata—never prompts or responses."
        ) {
            Text(ContributionsPresentation.updateText(lastUpdated, relativeTo: now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        ContributionBalanceHero(snapshot: snapshot) {
            showsPayout = true
        }
        .padding(.top, 22)

        ContributionSummaryStrip(
            snapshot: snapshot,
            scope: store.scope,
            shownRecordCount: store.filteredLedger.count,
            shownRecordTokens: store.shownRecordsTokenCount
        )
            .padding(.top, 12)

        if store.isEmpty {
            emptyGuidance
                .padding(.top, 12)
        }

        if let pulsePreview = store.pulsePreview {
            HStack(alignment: .top, spacing: 12) {
                ContributionPulseView(preview: pulsePreview)
                    .frame(maxWidth: .infinity)
                ContributionPrivacyNote()
                    .frame(width: 292)
            }
            .padding(.top, 12)
        } else {
            ContributionPrivacyNote()
                .padding(.top, 12)
        }

        ContributionLedgerView(
            store: store,
            asOf: now
        )
        .padding(.top, 24)
    }

    private var emptyGuidance: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 42, height: 42)
                .background(DarkbloomTheme.accent.opacity(0.09), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("No contributions yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("When this Mac completes private network work, its accounting record will bloom into this ledger.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Review availability") {
                onReviewAvailability()
            }
        }
        .padding(17)
        .productSurface()
    }

    private func unavailableContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductPageHeader(
                eyebrow: "Network",
                title: "Contributions are out of reach.",
                subtitle: "Your provider can keep running. Darkbloom just can’t load account totals in this UI preview right now."
            )

            HStack(spacing: 16) {
                Image(systemName: "chart.line.downtrend.xyaxis")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(Color.secondary.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Account data unavailable")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Try again") {
                        store.retryPreviewLoad()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Diagnostics") {
                        onOpenDiagnostics()
                    }
                }
            }
            .padding(20)
            .productSurface()
            .padding(.top, 24)
        }
    }
}
