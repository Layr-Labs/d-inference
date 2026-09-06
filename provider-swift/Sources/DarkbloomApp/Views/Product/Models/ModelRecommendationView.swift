import SwiftUI

struct ModelRecommendationView: View {
    let model: ModelSummary
    let isSelected: Bool
    let allowsSelection: Bool
    let offersLocalStart: Bool
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void
    let onRemove: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                Label("A good place to start", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.accent)
                Button { showsDetails = true } label: {
                    Text(model.displayName)
                        .font(DarkbloomTheme.chivo(25, weight: .medium))
                        .tracking(-0.5)
                        .foregroundStyle(StudioPalette.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("View model details")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    ModelLibraryModelDetails(model: model)
                }
                Text(model.isInstalled
                     ? "Installed and compatible"
                     : "\(ModelLibraryColumns.storage(model.sizeBytes)) download. Compatible with this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if model.isInstalled {
                        Text(ModelLibraryColumns.storage(model.sizeBytes))
                    }
                    if let quantization = model.quantization {
                        Text(quantization)
                    }
                    Text("Text generation")
                }
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ModelLibraryActions(
                model: model,
                isSelected: isSelected,
                allowsSelection: allowsSelection,
                offersLocalStart: offersLocalStart,
                isFeatured: true,
                onSelect: onSelect,
                onPrimaryAction: onPrimaryAction,
                onRemove: onRemove
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(20)
        .background(StudioPalette.accentSoft, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
