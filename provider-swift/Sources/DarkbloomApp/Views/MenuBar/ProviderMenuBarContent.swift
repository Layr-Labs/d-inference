enum ProviderMenuBarContent: Equatable, Sendable {
    case setup
    case provider(ProviderSnapshot)

    static func resolve(
        hasCompletedSetup: Bool,
        snapshot: @autoclosure () -> ProviderSnapshot
    ) -> ProviderMenuBarContent {
        guard hasCompletedSetup else { return .setup }
        return .provider(snapshot())
    }

    var showsProviderControls: Bool {
        if case .provider = self { return true }
        return false
    }
}
