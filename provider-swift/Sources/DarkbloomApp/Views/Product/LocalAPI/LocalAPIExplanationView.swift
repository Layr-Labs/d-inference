import SwiftUI

struct LocalAPIExplanationView: View {
    let endpoint: LocalAPIEndpointSnapshot

    var body: some View {
        LocalAPIDisclosure("Connection details") {
            VStack(alignment: .leading, spacing: 18) {
                detail(
                    "Mode",
                    value: LocalAPIPresentation.modeTitle(endpoint.mode),
                    explanation: LocalAPIPresentation.modeDetail(endpoint.mode)
                )
                detail(
                    "Access",
                    value: LocalAPIPresentation.accessTitle(endpoint.bindScope),
                    explanation: LocalAPIPresentation.accessDetail(endpoint.bindScope)
                )
                detail(
                    "Models",
                    value: LocalAPIPresentation.availableModelSummary(endpoint.modelCatalog),
                    explanation: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
                )

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("Provider")
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .frame(width: 88, alignment: .leading)
                    Text("Version \(endpoint.version) · Process \(endpoint.pid)")
                        .textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("Discovery")
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .frame(width: 88, alignment: .leading)
                    Text(endpoint.updatedAt, format: .dateTime.month().day().hour().minute().second())
                }
                .accessibilityLabel("Discovery record updated")
                .accessibilityValue(endpoint.updatedAt.formatted(date: .abbreviated, time: .standard))
            }
            .font(.system(size: 12))
            .foregroundStyle(StudioPalette.ink)
        }
    }

    private func detail(_ label: String, value: String, explanation: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
