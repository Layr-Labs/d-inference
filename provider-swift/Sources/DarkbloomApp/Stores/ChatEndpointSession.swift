import Foundation
import ProviderCoreFoundation

/// A per-operation trusted discovery snapshot. Never cache it between sends:
/// local serving may restart or the recorded PID may be reused.
struct ChatEndpointSession {
    let info: LocalEndpointInfo
    let client: LocalEndpointClient
    let configuration: LiveChatConfiguration

    init(configuration: LiveChatConfiguration, probe: Bool = false) throws {
        guard let info = configuration.discoveryReader() else { throw ChatFailure.noDiscovery }
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info, readIdentity: configuration.processIdentityReader
        ) else { throw ChatFailure.untrustedDiscovery }
        self.info = info
        self.configuration = configuration
        self.client = probe
            ? configuration.probeClientFactory(info)
            : configuration.clientFactory(info)
    }

    func validate() throws {
        try Task.checkCancellation()
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info, readIdentity: configuration.processIdentityReader
        ) else { throw ChatFailure.untrustedDiscovery }
    }

    func resolveModel(selectedModelID: String?) async throws -> (id: String, catalog: [String]) {
        // A readiness probe or restored conversation may describe a different
        // serving process/catalog. Validate every attempt, including retries.
        let models = try await client.listModels()
        try validate()
        guard let first = models.first else { throw ChatFailure.noModels }
        if let selectedModelID, !selectedModelID.isEmpty {
            guard models.contains(selectedModelID) else { throw ChatFailure.selectedModelUnavailable }
            return (selectedModelID, models)
        }
        let preferred = configuration.modelProvider()
        return (preferred.flatMap { models.contains($0) ? $0 : nil } ?? first, models)
    }

    static func failure(for error: Error) -> ChatFailure {
        if let failure = error as? ChatFailure { return failure }
        if let error = error as? LocalEndpointError { return .from(error) }
        return .from(.unreachable(error.localizedDescription))
    }
}
