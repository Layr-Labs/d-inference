import Foundation

protocol ProviderRuntimeServicing: Sendable {
    func currentSnapshot() async throws -> ProviderSnapshot
    func updates() async -> AsyncStream<ProviderSnapshot>

    @discardableResult
    func perform(_ action: ProviderAction) async throws -> ProviderSnapshot
}

enum ProviderRuntimeServiceError: Error, Equatable, LocalizedError, Sendable {
    case actionUnavailable(ProviderAction, state: ProviderRunState)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .actionUnavailable(let action, let state):
            "\(action.title) is unavailable while Darkbloom is \(state.rawValue)."
        case .unavailable(let message):
            message
        }
    }
}
