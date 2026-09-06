import SwiftUI

struct ModelLibraryCollectionView: View {
    let collection: ModelLibraryCollection
    let scope: ModelScope
    let isSearching: Bool
    let selectedModelID: String?
    let allowsSelection: Bool
    let offersLocalStart: Bool
    let onSelect: (ModelSummary) -> Void
    let onPrimaryAction: (ModelSummary) -> Void
    let onRemove: (ModelSummary) -> Void

    @State private var showsOtherLocalModels = false

    private var onlyLocalModels: Bool {
        collection.catalogModels.isEmpty && collection.recommendation?.isInstalled != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let model = collection.recommendation {
                ModelRecommendationView(
                    model: model,
                    isSelected: selectedModelID == model.id,
                    allowsSelection: allowsSelection,
                    offersLocalStart: offersLocalStart,
                    onSelect: { onSelect(model) },
                    onPrimaryAction: { onPrimaryAction(model) },
                    onRemove: { onRemove(model) }
                )
            }

            if !collection.catalogModels.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ProductSectionHeader(
                        scope == .installed ? "On this Mac" : "Compare models",
                        detail: "\(collection.catalogModels.count) \(isSearching ? "matching" : "models")"
                    )
                    modelList(collection.catalogModels)
                }
            }

            if !collection.otherLocalModels.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { showsOtherLocalModels || isSearching || onlyLocalModels },
                    set: { showsOtherLocalModels = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Locally discovered models. Check their compatibility details before starting.")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        modelList(collection.otherLocalModels)
                    }
                    .padding(.top, 12)
                } label: {
                    HStack(spacing: 8) {
                        Text(onlyLocalModels ? "On this Mac" : "Other local models")
                            .font(.system(size: 13, weight: .medium))
                        Text("\(collection.otherLocalModels.count)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(StudioPalette.secondaryInk)
                    }
                    .padding(.vertical, 5)
                }
                .tint(StudioPalette.secondaryInk)
            }
        }
    }

    private func modelList(_ models: [ModelSummary]) -> some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: ModelLibraryColumns.spacing) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Storage").frame(width: ModelLibraryColumns.storageWidth, alignment: .trailing)
                Text("Compatibility").frame(width: ModelLibraryColumns.compatibilityWidth, alignment: .leading)
                Color.clear.frame(width: ModelLibraryColumns.actionWidth, height: 1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(StudioPalette.secondaryInk)
            .padding(.vertical, 11)
            .accessibilityHidden(true)

            ForEach(models) { model in
                Rectangle().fill(StudioPalette.line).frame(height: 1)
                ModelLibraryRow(
                    model: model,
                    isSelected: selectedModelID == model.id,
                    allowsSelection: allowsSelection,
                    offersLocalStart: offersLocalStart,
                    onSelect: { onSelect(model) },
                    onPrimaryAction: { onPrimaryAction(model) },
                    onRemove: { onRemove(model) }
                )
            }
        }
        .padding(.horizontal, 14)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
