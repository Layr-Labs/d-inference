import Testing
@testable import ProviderCore

/// 0.10.13 default flip: `DARKBLOOM_CBV2_MTP_GRAMMAR` is on unless the operator sets it
/// (`0` = 0.10.12), and the LaunchAgent forwards the operator's value.
@Suite("SDK default: DARKBLOOM_CBV2_MTP_GRAMMAR")
struct SDKDefaultGrammarMTPTests {
    @Test func isOnByDefaultAndKillable() {
        #expect(SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_CBV2_MTP_GRAMMAR"))
        #expect(SDKFeatureDefaults.projection(environment: [:])["DARKBLOOM_CBV2_MTP_GRAMMAR"] == "1")
        #expect(SDKFeatureDefaults.projection(environment: ["DARKBLOOM_CBV2_MTP_GRAMMAR": "0"])["DARKBLOOM_CBV2_MTP_GRAMMAR"] == nil)
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_CBV2_MTP_GRAMMAR"))
    }
}
