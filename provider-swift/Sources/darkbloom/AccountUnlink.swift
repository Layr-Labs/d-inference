import Foundation
import ProviderCore

struct AccountUnlinkDependencies {
    var stopWatchdog: () throws -> Void
    var stopProviderService: () throws -> Void
    var terminateRecordedProvider: () -> Bool
    var revokeToken: (String, String) async throws -> Void
    var deleteToken: () throws -> Void
    var deleteAccount: () throws -> Void
    var deleteIssuer: () throws -> Void

    @MainActor
    static let live = AccountUnlinkDependencies(
        stopWatchdog: WatchdogAgent.stop,
        stopProviderService: LaunchAgent.stop,
        terminateRecordedProvider: {
            ProcessLifecycle.terminateRecordedInstance()
        },
        revokeToken: { token, coordinatorURL in
            try await ProviderTokenRevoker().revoke(
                coordinatorURL: coordinatorURL,
                token: token
            )
        },
        deleteToken: AuthTokenStore.delete,
        deleteAccount: ProviderAccountStore.delete,
        deleteIssuer: ProviderIssuerStore.delete
    )
}

@discardableResult
@MainActor
func unlinkProviderAccount(
    token: String?,
    coordinatorURL: String,
    dependencies: AccountUnlinkDependencies = .live
) async throws -> Bool {
    // Stop recovery first so it cannot relaunch a provider between service
    // shutdown and credential deletion.
    try dependencies.stopWatchdog()
    try dependencies.stopProviderService()
    guard dependencies.terminateRecordedProvider() else {
        throw AccountUnlinkError.providerDidNotStop
    }

    if let token, !token.isEmpty {
        // Revoke before deleting the only local copy. A transient coordinator
        // failure leaves credentials intact so the operator can retry safely.
        try await dependencies.revokeToken(token, coordinatorURL)
    }
    try dependencies.deleteToken()
    try dependencies.deleteAccount()
    try dependencies.deleteIssuer()
    return token != nil
}

enum AccountUnlinkError: LocalizedError, Equatable {
    case providerDidNotStop

    var errorDescription: String? {
        switch self {
        case .providerDidNotStop:
            return "the running provider could not be stopped; account credentials were preserved"
        }
    }
}

func accountUnlinkCoordinatorURL(configOptions: ConfigOptions) -> String {
    if let issuer = ProviderIssuerStore.load() {
        return issuer
    }
    let configured = (try? loadRuntimeSnapshot(configOptions: configOptions))?
        .config.coordinator.url
    return resolveAccountUnlinkCoordinatorURL(
        storedIssuer: nil,
        configuredCoordinator: configured
    )
}

func resolveAccountUnlinkCoordinatorURL(
    storedIssuer: String?,
    configuredCoordinator: String?
) -> String {
    storedIssuer
        ?? configuredCoordinator
        ?? "wss://api.darkbloom.dev/ws/provider"
}
