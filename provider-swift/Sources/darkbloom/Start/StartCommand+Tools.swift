import ArgumentParser
import Foundation
import ProviderCore

// `darkbloom start --opencode` / `--hermes`: start Darkbloom only if no local API runs, then point the tools at it
// (ToolIntegrationStep). They run once, at start: never in the launchd child, never per request.
extension Start {
    /// Red skeleton: nothing is refused, no running local API is used, nothing waits.
    var toolFlagsRefusal: String? { nil }

    func runningLocalAPI(_ live: LocalEndpoint.Info?, keyFile: (UInt16) -> URL?,
                         ignoringWhatServes: Bool = false) -> IntegrationEndpoint? { nil }

    func configuredCoordinatorURL() -> String { BuildEnvironment.current.coordinatorWebSocketURL }

    func setUpToolsBesidePair() async throws {}

    func setUpTools(endpoint: IntegrationEndpoint, route: LocalSettings.Route?, accountKeySaved: Bool?,
                    coordinatorURL: String) async -> Bool { true }

    static func waitForLocalAPI(port: UInt16, seconds: Int,
                                live: () -> LocalEndpoint.Info? = { LocalEndpoint.readLiveInfo() },
                                keyFile: (UInt16) -> URL? = { LocalEndpoint.keyFile(forPort: Int($0)) },
                                pause: () async -> Void = {}) async -> IntegrationEndpoint? { nil }
}
