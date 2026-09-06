import SwiftUI

struct ModelTransferSection: View {
    let models: [ModelSummary]
    let onPause: (ModelSummary.ID) -> Void
    let onResume: (ModelSummary.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProductSectionHeader("Downloads", detail: "\(models.count) in progress")
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    ModelTransferRow(
                        model: model,
                        onPause: { onPause(model.id) },
                        onResume: { onResume(model.id) }
                    )
                    .padding(14)
                    if index < models.count - 1 {
                        Rectangle().fill(StudioPalette.line).frame(height: 1)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
