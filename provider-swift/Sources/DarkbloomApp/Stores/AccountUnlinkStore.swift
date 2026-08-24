import Foundation
import Observation

enum AccountUnlinkState: Equatable, Sendable {
    case idle
    case unlinking
    case succeeded
    case failed(message: String)

    var isUnlinking: Bool {
        if case .unlinking = self { return true }
        return false
    }
}

/// Native-app adapter for the shipped `darkbloom logout` transaction.
///
/// The CLI owns service shutdown, process termination, coordinator revocation,
/// and credential deletion ordering. This store deliberately does not recreate
/// any of that security-sensitive logic; it only presents state and refreshes
/// app data after the CLI reports success.
@MainActor
@Observable
final class AccountUnlinkStore {
    private(set) var state: AccountUnlinkState = .idle

    @ObservationIgnored
    private let cli: any ProviderCLIRunning
    @ObservationIgnored
    private let timeout: Duration
    @ObservationIgnored
    private let refreshAfterSuccess: @MainActor @Sendable () async -> Void

    init(
        cli: any ProviderCLIRunning = ProcessProviderCLIRunner(),
        timeout: Duration = .seconds(90),
        refreshAfterSuccess: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.cli = cli
        self.timeout = timeout
        self.refreshAfterSuccess = refreshAfterSuccess
    }

    func unlinkThisMac() async {
        guard !state.isUnlinking else { return }
        state = .unlinking

        do {
            let result = try await cli.run(arguments: ["logout"], timeout: timeout)
            guard result.exitStatus == 0 else {
                throw ProviderCLIError.exited(
                    result.exitStatus,
                    message: result.failureMessage
                )
            }
            // Account/session state must not move until the CLI has completed
            // revocation and local credential deletion successfully.
            await refreshAfterSuccess()
            state = .succeeded
        } catch is CancellationError {
            state = .failed(message: AccountUnlinkPresentation.interruptedMessage)
        } catch {
            state = .failed(message: AccountUnlinkPresentation.failureMessage(
                detail: error.localizedDescription
            ))
        }
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }
}
