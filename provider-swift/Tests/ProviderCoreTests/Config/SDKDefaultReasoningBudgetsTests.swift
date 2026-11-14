import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_NATIVE_REASONING_BUDGET` is on unless the operator sets it
/// (`0` = 0.10.12), and the LaunchAgent forwards the operator's value.
@Suite("SDK default: DARKBLOOM_NATIVE_REASONING_BUDGET")
struct SDKDefaultReasoningBudgetsTests {
    @Test func isOnByDefaultAndKillable() {
        #expect(SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_NATIVE_REASONING_BUDGET"))
        #expect(SDKFeatureDefaults.projection(environment: [:])["DARKBLOOM_NATIVE_REASONING_BUDGET"] == "1")
        #expect(SDKFeatureDefaults.projection(environment: ["DARKBLOOM_NATIVE_REASONING_BUDGET": "0"])["DARKBLOOM_NATIVE_REASONING_BUDGET"] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_NATIVE_REASONING_BUDGET"))
    }
}
