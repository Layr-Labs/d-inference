import SwiftUI

struct FocusedProviderActions {
    let primaryTitle: String
    let canPerformPrimary: Bool
    let performPrimary: () -> Void
    let restartTitle: String
    let canRestart: Bool
    let restart: () -> Void
    let showDiagnostics: () -> Void
}

private struct FocusedProviderActionsKey: FocusedValueKey {
    typealias Value = FocusedProviderActions
}

extension FocusedValues {
    var providerActions: FocusedProviderActions? {
        get { self[FocusedProviderActionsKey.self] }
        set { self[FocusedProviderActionsKey.self] = newValue }
    }
}

struct ProviderCommands: Commands {
    @FocusedValue(\.providerActions) private var actions

    var body: some Commands {
        CommandMenu("Provider") {
            Button(actions?.primaryTitle ?? "Change Availability") {
                actions?.performPrimary()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(actions?.canPerformPrimary != true)

            Button(actions?.restartTitle ?? "Restart Network Provider") {
                actions?.restart()
            }
            .disabled(actions?.canRestart != true)

            Divider()

            Button("Run System Check…") {
                actions?.showDiagnostics()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }
    }
}
