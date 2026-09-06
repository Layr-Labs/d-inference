import Foundation
import ProviderCoreFoundation

/// Pure translation of discovery evidence into Local API presentation state.
enum LocalAPIDiscoveryMapping {
    static func bootstrapState(
        info: LocalEndpointInfo?,
        processIdentityReader: @Sendable (Int32) -> ProcessIdentity?
    ) -> LocalAPIState {
        guard let info else {
            return .stopped(message: "No live local discovery record was found.")
        }
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: processIdentityReader
        ) else {
            return .stopped(message: "The local discovery record could not be matched to its original process. Check the provider controls or Diagnostics.")
        }
        return .running(Self.snapshot(from: info, health: .checking, modelCatalog: .loading))
    }

    /// Maps the wire discovery record onto the UI snapshot. `mode` stays nil:
    /// `local.json` does not record how the server was started, and the
    /// presentation layer reports "Mode not reported" rather than guessing.
    static func snapshot(
        from info: LocalEndpointInfo,
        health: LocalAPIHealth,
        modelCatalog: LocalAPIModelCatalog
    ) -> LocalAPIEndpointSnapshot {
        LocalAPIEndpointSnapshot(
            baseURL: URL(string: info.baseURL) ?? URL(string: "http://127.0.0.1:\(info.port)/v1")!,
            host: info.host,
            port: info.port,
            apiKey: info.apiKey.isEmpty ? nil : info.apiKey,
            pid: info.pid,
            version: info.version,
            updatedAt: ISO8601DateFormatter().date(from: info.updatedAt) ?? Date(timeIntervalSince1970: 0),
            mode: nil,
            health: health,
            modelCatalog: modelCatalog
        )
    }
}
