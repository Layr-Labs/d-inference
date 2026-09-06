import SwiftUI

struct ModelLibraryModelDetails: View {
    let model: ModelSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.displayName)
                    .font(DarkbloomTheme.chivo(22, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                Text(model.id)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .textSelection(.enabled)
                if !model.summary.isEmpty {
                    Text(model.summary)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ModelLibraryFitLabel(fit: model.fit)
                compatibilityDetail
                Divider()
                LabeledContent("Storage", value: ModelLibraryColumns.storage(model.sizeBytes))
                if let memory = model.minimumMemoryGB {
                    LabeledContent("Recommended memory", value: "\(memory) GB")
                }
                if let quantization = model.quantization {
                    LabeledContent("Quantization", value: quantization)
                }
                if let context = model.maxContextLength, context > 0 {
                    LabeledContent("Catalog context limit", value: "\(context.formatted()) tokens")
                }
                if !model.capabilities.isEmpty {
                    LabeledContent("Capabilities", value: model.capabilities.map(\.displayName).joined(separator: ", "))
                }
                LabeledContent("Source", value: sourceTitle)
            }
            .font(.system(size: 12))
            .foregroundStyle(StudioPalette.ink)
            .padding(22)
        }
        .frame(width: 360, height: 380)
        .background(StudioPalette.surface)
    }

    @ViewBuilder
    private var compatibilityDetail: some View {
        switch model.fit {
        case .tooLarge(let required, let available):
            Text("This model recommends \(required) GB of memory. This Mac has \(available) GB available for it, so loading may fail.")
                .foregroundStyle(StudioPalette.secondaryInk)
        case .runtimeIneligible(let reason), .runtimeUnknown(let reason):
            Text(reason).foregroundStyle(StudioPalette.secondaryInk)
        case .unknown:
            Text("Compatibility has not been established for this model.")
                .foregroundStyle(StudioPalette.secondaryInk)
        case .fits:
            EmptyView()
        }
    }

    private var sourceTitle: String {
        switch model.origin {
        case .catalog: "Darkbloom catalog"
        case .retired: "Previously in the catalog"
        case .localOnly: "Found on this Mac"
        }
    }
}
