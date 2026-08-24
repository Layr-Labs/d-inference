import SwiftUI

struct ModelLibraryRow: View {
    let model: ModelSummary
    let isSelected: Bool
    let allowsSelection: Bool
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: model.kind == .vision ? "eye" : "text.bubble")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(modelTint)
                .frame(width: 40, height: 40)
                .background(
                    modelTint.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    runtimeBadge
                }

                Text(model.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if case .failed(let failure) = model.installation {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ProductPalette.warning)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                    if let quantization = model.quantization {
                        Text("· \(quantization)")
                    }
                    if let minimumMemoryGB = model.minimumMemoryGB {
                        Text("· \(minimumMemoryGB) GB memory")
                    }
                    ForEach(model.capabilities.prefix(2), id: \.rawValue) { capability in
                        Text("· \(capability.displayName)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 14)

            compatibilityBadge

            primaryButton

            if model.isInstalled {
                Menu {
                    if allowsSelection {
                        Button("Use for private chat", action: onSelect)
                        Divider()
                    }
                    Button("Remove Download…", role: .destructive, action: onRemove)
                        .disabled(model.runtime != .cold)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(16)
        .productSurface()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.installation {
        case .notInstalled:
            Button("Download", action: onPrimaryAction)
                .buttonStyle(.bordered)
        case .downloading:
            Button("Pause", systemImage: "pause.fill", action: onPrimaryAction)
                .buttonStyle(.bordered)
        case .paused:
            Button("Resume", systemImage: "play.fill", action: onPrimaryAction)
                .buttonStyle(.borderedProminent)
        case .verifying:
            ProgressView()
                .controlSize(.small)
                .help("Verifying model weights")
        case .installed:
            if !model.fit.canRunOnThisMac {
                Button("Unavailable") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else if !allowsSelection {
                EmptyView()
            } else if isSelected {
                Button("Selected", systemImage: "checkmark", action: onPrimaryAction)
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else {
                Button("Use", systemImage: "sparkles", action: onPrimaryAction)
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let failure):
            Button(failure.isResumable ? "Resume" : "Download Again", action: onPrimaryAction)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var compatibilityBadge: some View {
        switch model.fit {
        case .fits:
            ProductStatusBadge(title: "Compatible", systemImage: "checkmark", tint: ProductPalette.positive)
        case .tooLarge:
            ProductStatusBadge(title: "Doesn’t fit this Mac", systemImage: "xmark", tint: ProductPalette.warning)
        case .unknown:
            ProductStatusBadge(title: "Compatibility unknown", systemImage: "questionmark", tint: .secondary)
        }
    }

    @ViewBuilder
    private var runtimeBadge: some View {
        switch model.runtime {
        case .serving:
            ProductStatusBadge(title: "Serving", systemImage: "waveform", tint: DarkbloomTheme.accent)
        case .warm:
            ProductStatusBadge(title: "Warm", systemImage: "bolt.fill", tint: ProductPalette.positive)
        case .loading:
            ProductStatusBadge(title: "Loading", systemImage: "ellipsis", tint: DarkbloomTheme.accent)
        case .reloading:
            ProductStatusBadge(title: "Reloading", systemImage: "arrow.clockwise", tint: DarkbloomTheme.accent)
        case .crashed:
            ProductStatusBadge(title: "Load failed", systemImage: "exclamationmark", tint: ProductPalette.critical)
        default:
            EmptyView()
        }
    }

    private var modelTint: Color {
        switch model.fit {
        case .fits: DarkbloomTheme.accent
        case .unknown, .tooLarge: .secondary
        }
    }
}
