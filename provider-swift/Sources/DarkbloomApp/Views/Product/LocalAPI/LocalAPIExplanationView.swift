import SwiftUI

struct LocalAPIExplanationView: View {
    let endpoint: LocalAPIEndpointSnapshot

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 34) {
                howItRuns
                Divider()
                privacyAndAccess
                Divider()
                availableModels
            }
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 1_200 : 700)

            VStack(alignment: .leading, spacing: 18) {
                howItRuns
                Divider()
                privacyAndAccess
                Divider()
                availableModels
            }
        }
        .padding(.vertical, 22)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var howItRuns: some View {
        explanationColumn(
            eyebrow: "How it runs",
            icon: endpoint.mode == .directOnly ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted",
            title: LocalAPIPresentation.modeTitle(endpoint.mode),
            detail: LocalAPIPresentation.modeDetail(endpoint.mode)
        )
    }

    private var privacyAndAccess: some View {
        explanationColumn(
            eyebrow: "Privacy & access",
            icon: endpoint.bindScope == .thisMac ? "lock.macwindow" : "network.badge.shield.half.filled",
            title: LocalAPIPresentation.accessTitle(endpoint.bindScope),
            detail: LocalAPIPresentation.accessDetail(endpoint.bindScope)
        )
    }

    private var availableModels: some View {
        explanationColumn(
            eyebrow: "Available models",
            icon: "shippingbox",
            title: LocalAPIPresentation.availableModelSummary(endpoint.modelCatalog),
            detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
        )
    }

    private func explanationColumn(
        eyebrow: String,
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DarkbloomTheme.accent)
                    .accessibilityHidden(true)

                Text(eyebrow.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
