import SwiftUI

/// Shared by the recommendation and comparison rows so actions retain the same gates.
struct ModelLibraryActions: View {
    let model: ModelSummary
    let isSelected: Bool
    let allowsSelection: Bool
    let offersLocalStart: Bool
    var isFeatured = false
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
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
                .menuIndicator(.hidden)
                .frame(width: 20)
                .accessibilityLabel("Actions for \(model.displayName)")
                .help(model.runtime == .cold ? "Model actions" : "Take this model offline before removing it")
            }
        }
        .controlSize(.small)
        .tint(StudioPalette.accent)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.installation {
        case .notInstalled:
            actionButton("Download")
        case .downloading:
            actionButton("Pause")
        case .paused:
            actionButton("Resume")
        case .verifying:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Verifying \(model.displayName)")
                .help("Verifying model weights")
        case .installed:
            if !model.fit.canRunOnThisMac {
                Button("Unavailable") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else if offersLocalStart {
                actionButton("Use in Chat")
                    .help("Open Chat with this model")
            } else if !allowsSelection {
                EmptyView()
            } else if isSelected {
                Button("Selected", systemImage: "checkmark") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else {
                actionButton("Use")
            }
        case .failed(let failure):
            actionButton(failure.isResumable ? "Resume" : "Download Again")
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String) -> some View {
        if isFeatured {
            Button(title, action: onPrimaryAction)
                .buttonStyle(StudioPrimaryButtonStyle())
        } else {
            Button(title, action: onPrimaryAction)
                .buttonStyle(.bordered)
        }
    }
}
