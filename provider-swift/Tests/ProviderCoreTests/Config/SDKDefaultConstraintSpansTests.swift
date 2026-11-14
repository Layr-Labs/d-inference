import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_CONSTRAINT_SPANS` is on unless the operator sets it
/// (`0` = 0.10.12), and the LaunchAgent forwards the operator's value.
@Suite("SDK default: DARKBLOOM_CONSTRAINT_SPANS")
struct SDKDefaultConstraintSpansTests {
    @Test func isOnByDefaultAndKillable() {
        #expect(SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_CONSTRAINT_SPANS"))
        #expect(SDKFeatureDefaults.projection(environment: [:])["DARKBLOOM_CONSTRAINT_SPANS"] == "1")
        #expect(SDKFeatureDefaults.projection(environment: ["DARKBLOOM_CONSTRAINT_SPANS": "0"])["DARKBLOOM_CONSTRAINT_SPANS"] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_CONSTRAINT_SPANS"))
    }
}
