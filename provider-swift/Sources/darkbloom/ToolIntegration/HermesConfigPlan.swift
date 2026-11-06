import Foundation

/// The `providers.<id>` block and the main model in Hermes Agent's `config.yaml`.
enum HermesConfigPlan {
    static let minimumContext = 64_000

    static func configFile(home: URL, variables: [String: String]) -> URL {
        home.appendingPathComponent(".hermes/config.yaml")
    }

    static func plan(
        existing: Data?, endpoint: IntegrationEndpoint, models: [IntegrationModel], provider: IntegrationProvider
    ) -> ToolConfigPlan {
        .refused(.file("not built yet"))
    }
}
