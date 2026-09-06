/// A single projection of installation state onto every product surface.
///
/// Keeping these gates together prevents a recovery-only process from gaining
/// provider controls through a secondary scene even when the main window is
/// correctly showing recovery UI.
struct AppInstallScenePresentation {
    enum MainContent {
        case product
        case handingOff
        case recovery(AppInstallationRecovery)
        case failure(AppInstallationFailure)
    }

    let mainContent: MainContent

    init(installState: AppInstallLaunchState) {
        switch installState {
        case .ready:
            mainContent = .product
        case .handingOff:
            mainContent = .handingOff
        case .relaunchRequired(let recovery):
            mainContent = .recovery(recovery)
        case .failed(let failure):
            mainContent = .failure(failure)
        }
    }

    var showsProductContent: Bool {
        if case .product = mainContent { return true }
        return false
    }

    var showsProviderCommands: Bool { showsProductContent }
    var showsProductSettings: Bool { showsProductContent }
    var showsProviderMenuControls: Bool { showsProductContent }
}
