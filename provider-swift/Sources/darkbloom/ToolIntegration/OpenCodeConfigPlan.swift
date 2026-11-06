import Foundation

/// The `providers.<id>` block in OpenCode 2's global config.
enum OpenCodeConfigPlan {
    static let schemaURL = "https://opencode.ai/config.json"

    static func configFile(home: URL, variables: [String: String]) -> URL {
        home.appendingPathComponent(".config/opencode/opencode.jsonc")
    }

    static func plan(
        existing: Data?, fileName: String, endpoint: IntegrationEndpoint, models: [IntegrationModel],
        provider: IntegrationProvider, home: URL
    ) -> ToolConfigPlan {
        .refused(.file("not built yet"))
    }
}
