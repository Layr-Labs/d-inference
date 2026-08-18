import SwiftUI

struct ModelTransferSection: View {
    let models: [ModelSummary]
    let onPause: (ModelSummary.ID) -> Void
    let onResume: (ModelSummary.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProductSectionHeader("Preparing models", detail: "Verified downloads")

            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    ModelTransferRow(
                        model: model,
                        onPause: { onPause(model.id) },
                        onResume: { onResume(model.id) }
                    )
                    .padding(16)

                    if index < models.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .productSurface()
        }
    }
}
