import SwiftUI

struct ProductToolbar: ToolbarContent {
    let destination: ProductDestination
    let snapshot: ProviderSnapshot
    let primaryAction: ProviderAction
    let actionIsPending: Bool
    let canPerformPrimaryAction: Bool
    let canRestart: Bool
    let onOverview: () -> Void
    let onPerformPrimaryAction: () -> Void
    let onRestart: () -> Void
    let onDiagnostics: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if destination != .overview {
                Button(action: onOverview) {
                    Label("Overview", systemImage: "chevron.left")
                }
                .help("Back to Overview")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if destination == .localAPI {
                Button("Run System Check…", systemImage: "stethoscope", action: onDiagnostics)
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            } else if destination == .myMacs
                || destination == .availability
                || snapshot.runState == .scheduledOff
            {
                Button(
                    destination == .myMacs || destination == .availability
                        ? "Run This Mac’s System Check…"
                        : "Run System Check…",
                    systemImage: "stethoscope",
                    action: onDiagnostics
                )
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            } else {
                if actionIsPending {
                    ProgressView()
                        .controlSize(.small)
                        .help("Darkbloom is changing network provider state")
                }

                Button(action: onPerformPrimaryAction) {
                    Label(primaryAction.title, systemImage: primaryAction.systemImage)
                }
                .disabled(!canPerformPrimaryAction)

                Menu {
                    Button("Restart Network Provider", systemImage: "arrow.clockwise", action: onRestart)
                        .disabled(!canRestart)
                    Button("Run System Check…", systemImage: "stethoscope", action: onDiagnostics)
                    Divider()
                    SettingsLink {
                        Label("Settings…", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}
