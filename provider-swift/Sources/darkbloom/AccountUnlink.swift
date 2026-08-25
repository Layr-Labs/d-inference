import Foundation
import ProviderCore

struct AccountUnlinkDependencies {
    var stopWatchdog: () throws -> Void
    var stopProviderService: () throws -> Void
    var terminateRecordedProvider: () -> Bool
    var revokeToken: (String, String) async throws -> Void
    var deleteCredential: (ProviderCredential?) throws -> Void

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
        deleteCredential: ProviderCredentialStore.delete
    )
}

@discardableResult
@MainActor
func unlinkProviderAccount(
    credential: ProviderCredential?,
    dependencies: AccountUnlinkDependencies = .live
) async throws -> Bool {
    // Stop recovery first so it cannot relaunch a provider between service
    // shutdown and credential deletion.
    try dependencies.stopWatchdog()
    try dependencies.stopProviderService()
    guard dependencies.terminateRecordedProvider() else {
        throw AccountUnlinkError.providerDidNotStop
    }

    if let credential {
        // Revoke before deleting the only local copy. A transient coordinator
        // failure leaves credentials intact so the operator can retry safely.
        try await dependencies.revokeToken(
            credential.token,
            credential.issuer
        )
    }
    try dependencies.deleteCredential(credential)
    return credential != nil
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
