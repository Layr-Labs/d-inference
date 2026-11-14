import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_GEMMA_REOPENED_THOUGHTS` is on unless the operator sets it
/// (`0` = 0.10.12), and the LaunchAgent forwards the operator's value.
@Suite("SDK default: DARKBLOOM_GEMMA_REOPENED_THOUGHTS")
struct SDKDefaultGemmaReopenedThoughtsTests {
    @Test func isOnByDefaultAndKillable() {
        let key = "DARKBLOOM_GEMMA_REOPENED_THOUGHTS"
        #expect(SDKFeatureDefaults.onByDefault.contains(key))
        #expect(SDKFeatureDefaults.projection(environment: [:])[key] == "1")
        #expect(SDKFeatureDefaults.projection(environment: [key: "0"])[key] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains(key))
    }
}
