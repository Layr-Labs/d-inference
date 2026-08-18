import SwiftUI

struct ProviderActivityView: View {
    let snapshot: ProviderSnapshot

    private var presentation: ProviderStatusPresentation {
        snapshot.statusPresentation
    }

    var body: some View {
        ProductPage {
            ProductPageHeader(
                eyebrow: "Activity",
                title: "What this Mac is doing.",
                subtitle: "A private, content-free view of the current provider session. Prompts and responses never appear here."
            ) {
                ProductStatusBadge(
                    title: presentation.badgeTitle,
                    systemImage: presentation.icon,
                    tint: presentation.tint
                )
            }

            currentActivity
                .padding(.top, 26)

            ProductSectionHeader("This provider session", detail: "Counters reset when the provider restarts")
                .padding(.top, 28)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ProductMetricTile(
                    label: "Requests served",
                    value: snapshot.activity.requestsServed.formatted(),
                    detail: "Since provider started"
                )
                ProductMetricTile(
                    label: "Tokens generated",
                    value: ProductFormat.compactCount(snapshot.activity.tokensGenerated),
                    detail: "Since provider started"
                )
                ProductMetricTile(
                    label: "Session uptime",
                    value: ProductFormat.duration(snapshot.uptime),
                    detail: snapshot.pid.map { "Process \($0)" } ?? "Provider is offline"
                )
            }
            .padding(.top, 10)

            HStack(alignment: .top, spacing: 14) {
                modelActivity
                usageIntegrity
            }
            .padding(.top, 28)
        }
        .navigationTitle("Activity")
    }

    private var currentActivity: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(presentation.tint.opacity(0.10))
                    .frame(width: 54, height: 54)
                Image(systemName: presentation.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(presentation.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.activityTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(presentation.activityDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Spacer()

            if snapshot.isServing {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("CURRENT MODEL")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Text(snapshot.currentModel?.displayName ?? "Loading model")
                        .font(.system(size: 13, weight: .medium))
                }
            }
        }
        .padding(20)
        .productSurface()
    }

    private var modelActivity: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("Models in memory")

            VStack(spacing: 0) {
                if snapshot.warmModels.isEmpty {
                    ProductDisclosureRow(
                        icon: "shippingbox",
                        title: "No models loaded",
                        detail: "Models load when private or network inference begins.",
                        tint: .secondary,
                        showsChevron: false
                    )
                    .padding(16)
                } else {
                    ForEach(Array(snapshot.warmModels.enumerated()), id: \.element.id) { index, model in
                        ProductDisclosureRow(
                            icon: model.isVision ? "eye" : "text.bubble",
                            title: model.displayName,
                            detail: modelDetail(model),
                            tint: modelIsServing(model) ? DarkbloomTheme.accent : ProductPalette.positive,
                            showsChevron: false
                        )
                        .padding(16)

                        if index < snapshot.warmModels.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }
            .productSurface()
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var usageIntegrity: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("Usage integrity")

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: snapshot.activity.usageGaps == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(snapshot.activity.usageGaps == 0 ? ProductPalette.positive : ProductPalette.warning)
                    Spacer()
                    Text(snapshot.activity.usageGaps.formatted())
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }

                Text(snapshot.activity.usageGaps == 0 ? "No accounting gaps" : "Usage gaps detected")
                    .font(.system(size: 14, weight: .semibold))
                Text("Darkbloom tracks whether every completed request has a matching usage record—never its prompt content.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(17)
            .productSurface()
            .padding(.top, 10)
        }
        .frame(width: 300, alignment: .topLeading)
    }

    private func modelDetail(_ model: ProviderModelSummary) -> String {
        guard model.id == snapshot.currentModel?.id else { return "Warm and ready" }
        return snapshot.isServing ? "Serving now" : "Loaded and ready"
    }

    private func modelIsServing(_ model: ProviderModelSummary) -> Bool {
        snapshot.isServing && model.id == snapshot.currentModel?.id
    }
}
