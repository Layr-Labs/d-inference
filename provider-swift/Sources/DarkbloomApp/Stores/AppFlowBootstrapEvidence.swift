struct AppFlowBootstrapEvidence: Equatable, Sendable {
    let hasProviderState: Bool
    let hasVerifiedHardwareTrust: Bool

    init(
        hasProviderState: Bool,
        hasVerifiedHardwareTrust: Bool
    ) {
        self.hasProviderState = hasProviderState
        self.hasVerifiedHardwareTrust = hasVerifiedHardwareTrust
    }

    init(snapshot: ProviderSnapshot) {
        let trustLevel = snapshot.trust.level.lowercased()
        hasProviderState = snapshot.version != "unknown" &&
            snapshot.isRunning &&
            !snapshot.isStale
        hasVerifiedHardwareTrust = snapshot.trust.state == .verified &&
            (trustLevel == "hardware" || trustLevel == "mda_verified")
    }

    var canOpenProductWithoutOnboarding: Bool {
        hasProviderState && hasVerifiedHardwareTrust
    }
}
