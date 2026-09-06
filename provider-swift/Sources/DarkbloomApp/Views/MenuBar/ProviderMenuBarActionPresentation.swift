enum ProviderMenuBarActionPresentation {
    static func title(_ action: ProviderAction) -> String {
        switch action {
        case .start: "Start sharing"
        case .stop: "Pause sharing"
        case .restart: "Restart sharing"
        case .refresh: "Check network status"
        case .runDiagnostics: "Check network provider"
        }
    }

    /// Network start/restart can replace a foreground process. Keep the
    /// app-owned local session protected, including while it is being reaped.
    static func isBlocked(_ action: ProviderAction, hasActiveLocalSession: Bool) -> Bool {
        hasActiveLocalSession && (action == .start || action == .restart)
    }
}

struct ProviderMenuBarActionConfirmation {
    let action: ProviderAction
    let title: String
    let message: String
    let buttonTitle: String

    init?(action: ProviderAction, snapshot: ProviderSnapshot) {
        // Preserve the existing set of confirmation-required actions.
        guard ProviderActionConfirmation(action: action, snapshot: snapshot) != nil else { return nil }
        self.action = action
        buttonTitle = ProviderMenuBarActionPresentation.title(action)
        switch action {
        case .stop:
            title = "Pause network sharing?"
            message = (snapshot.isServing ? "Active requests may be interrupted. " : "")
                + "The network provider and its local endpoint will stop. Sharing stays paused across restarts until you start it again."
        case .restart:
            title = "Restart network sharing?"
            message = (snapshot.isServing ? "Active requests may be interrupted. " : "")
                + "The network provider and its local endpoint will briefly stop, then the provider will reconnect."
        case .start, .refresh, .runDiagnostics:
            return nil
        }
    }
}
