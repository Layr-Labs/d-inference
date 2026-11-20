import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_GEMMA_SCHEMA_COERCION` is set in every `darkbloom` process unless
/// the operator sets it (`0` = 0.10.12), never persisted, and the LaunchAgent
/// forwards the operator's value.
@Suite("SDK default: DARKBLOOM_GEMMA_SCHEMA_COERCION")
struct SDKDefaultGemmaQuotedNumbersTests {
    @Test func isOnByDefaultAndKillable() {
        #expect(SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_GEMMA_SCHEMA_COERCION"))
        #expect(SDKFeatureDefaults.plan(environment: [:]).set["DARKBLOOM_GEMMA_SCHEMA_COERCION"] == "1")
        #expect(SDKFeatureDefaults.plan(environment: ["DARKBLOOM_GEMMA_SCHEMA_COERCION": "0"]).set["DARKBLOOM_GEMMA_SCHEMA_COERCION"] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_GEMMA_SCHEMA_COERCION"))
        #expect(LaunchAgent.passthroughEnvironment(from: ["DARKBLOOM_GEMMA_SCHEMA_COERCION": "1"], injected: ["DARKBLOOM_GEMMA_SCHEMA_COERCION"])["DARKBLOOM_GEMMA_SCHEMA_COERCION"] == nil)
    }
}
