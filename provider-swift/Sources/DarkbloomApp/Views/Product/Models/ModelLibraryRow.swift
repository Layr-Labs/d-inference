import SwiftUI

struct ModelLibraryRow: View {
    let model: ModelSummary
    let isSelected: Bool
    let allowsSelection: Bool
    var offersLocalStart = false
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void
    let onRemove: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: ModelLibraryColumns.spacing) {
                Button { showsDetails = true } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioPalette.ink)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                        Text(capabilityDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(StudioPalette.secondaryInk)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View details for \(model.displayName)")
                .accessibilityLabel("Details for \(model.displayName)")
                .popover(isPresented: $showsDetails, arrowEdge: .leading) {
                    ModelLibraryModelDetails(model: model)
                }

                Text(ModelLibraryColumns.storage(model.sizeBytes))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .frame(width: ModelLibraryColumns.storageWidth, alignment: .trailing)
                    .accessibilityLabel("Storage: \(ModelLibraryColumns.storage(model.sizeBytes))")

                VStack(alignment: .leading, spacing: 4) {
                    ModelLibraryFitLabel(fit: model.fit)
                    if let runtimeTitle {
                        Text(runtimeTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioPalette.secondaryInk)
                    }
                }
                .frame(width: ModelLibraryColumns.compatibilityWidth, alignment: .leading)

                ModelLibraryActions(
                    model: model,
                    isSelected: isSelected,
                    allowsSelection: allowsSelection,
                    offersLocalStart: offersLocalStart,
                    onSelect: onSelect,
                    onPrimaryAction: onPrimaryAction,
                    onRemove: onRemove
                )
                .frame(width: ModelLibraryColumns.actionWidth, alignment: .trailing)
            }

            if case .failed(let failure) = model.installation {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(ProductPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private var capabilityDetail: String {
        let capabilities = model.capabilities.map(\.displayName).joined(separator: ", ")
        if !capabilities.isEmpty { return capabilities }
        return model.quantization ?? "Details not provided"
    }

    private var runtimeTitle: String? {
        switch model.runtime {
        case .cold: nil
        case .serving: "Serving"
        case .warm: "Loaded"
        case .loading: "Loading"
        case .reloading: "Reloading"
        case .crashed: "Load failed"
        }
    }
}

/// Shared widths keep the collection readable as a comparison at a 900pt window.
/// The name column takes the remaining width and wraps instead of pushing actions out.
enum ModelLibraryColumns {
    static let spacing: CGFloat = 12
    static let storageWidth: CGFloat = 65
    static let compatibilityWidth: CGFloat = 110
    static let actionWidth: CGFloat = 126

    static func storage(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Unknown"
    }
}

struct ModelLibraryFitLabel: View {
    let fit: ModelFit

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fit == .fits ? StudioPalette.accent : StudioPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .help(detail)
    }

    private var title: String {
        switch fit {
        case .fits: "Fits this Mac"
        case .tooLarge: "Needs more memory"
        case .unknown: "Not checked"
        case .runtimeIneligible: "Unsupported"
        case .runtimeUnknown: "Not verified"
        }
    }

    private var symbol: String {
        switch fit {
        case .fits: "checkmark.circle"
        case .tooLarge, .runtimeIneligible: "exclamationmark.circle"
        case .unknown, .runtimeUnknown: "questionmark.circle"
        }
    }

    private var detail: String {
        switch fit {
        case .fits: "Runtime support and memory fit passed the latest compatibility check."
        case .tooLarge(let required, let available):
            "Recommends \(required) GB of memory; this Mac has \(available) GB available for it."
        case .unknown: "Compatibility is unknown for this model."
        case .runtimeIneligible(let reason), .runtimeUnknown(let reason): reason
        }
    }
}
