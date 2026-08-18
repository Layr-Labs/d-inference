import Foundation

struct ProviderActionConfirmation: Equatable, Identifiable, Sendable {
    let action: ProviderAction
    let title: String
    let message: String
    let buttonTitle: String

    var id: ProviderAction { action }

    init?(action: ProviderAction, snapshot: ProviderSnapshot) {
        switch action {
        case .stop:
            self.action = action
            title = snapshot.isServing
                ? "Take this Mac offline while it is serving?"
                : "Take this Mac offline?"
            message = snapshot.isServing
                ? "Active work may be interrupted. This Mac will stay offline—even after a restart—until you make it available again."
                : "This Mac will stay offline—even after a restart—until you make it available again."
            buttonTitle = "Take Offline"
        case .restart:
            self.action = action
            title = snapshot.isServing
                ? "Restart while private work is active?"
                : "Restart Darkbloom?"
            message = snapshot.isServing
                ? "Restarting can interrupt active work. Darkbloom will reconnect when the provider is ready."
                : "Darkbloom will briefly stop local and network inference, then reconnect."
            buttonTitle = "Restart"
        case .start, .refresh, .runDiagnostics:
            return nil
        }
    }
}
