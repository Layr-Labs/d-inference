import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_GEMMA_SCHEMA_COERCION` is on unless the operator sets it
/// (`0` = 0.10.12), and the LaunchAgent forwards the operator's value.
@Suite("SDK default: DARKBLOOM_GEMMA_SCHEMA_COERCION")
struct SDKDefaultGemmaQuotedNumbersTests {
    @Test func isOnByDefaultAndKillable() {
        #expect(SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_GEMMA_SCHEMA_COERCION"))
        #expect(SDKFeatureDefaults.projection(environment: [:])["DARKBLOOM_GEMMA_SCHEMA_COERCION"] == "1")
        #expect(SDKFeatureDefaults.projection(environment: ["DARKBLOOM_GEMMA_SCHEMA_COERCION": "0"])["DARKBLOOM_GEMMA_SCHEMA_COERCION"] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_GEMMA_SCHEMA_COERCION"))
    }
}
