import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_GEMMA_REOPENED_THOUGHTS` is set in every `darkbloom` process unless
/// the operator sets it (`0` = 0.10.12), is trusted when a parent injected it, is never persisted,
/// and the LaunchAgent forwards the operator's value.
@Suite("SDK default: DARKBLOOM_GEMMA_REOPENED_THOUGHTS")
struct SDKDefaultGemmaReopenedThoughtsTests {
    @Test func isOnByDefaultAndKillable() {
        let key = "DARKBLOOM_GEMMA_REOPENED_THOUGHTS"
        #expect(SDKFeatureDefaults.onByDefault.contains(key))
        #expect(SDKFeatureDefaults.injectableKeys.contains(key))
        #expect(SDKFeatureDefaults.plan(environment: [:]).set[key] == "1")
        #expect(SDKFeatureDefaults.plan(environment: [key: "0"]).set[key] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"], injected: [key])[key] == nil)
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"], injected: [])[key] == "0")
    }
}
