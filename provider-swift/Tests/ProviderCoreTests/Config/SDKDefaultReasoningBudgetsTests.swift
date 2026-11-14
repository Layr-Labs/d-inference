import Testing
@testable import ProviderCore

/// 0.10.13 default flip, scoped to its evidence: `reasoning.max_tokens` budgets
/// are admitted for Nemotron 3.5 Super and MiMo V2.6 unless the operator sets
/// `DARKBLOOM_NATIVE_REASONING_BUDGET` (`0` = 0.10.12 for every family).
@Suite("SDK default: DARKBLOOM_NATIVE_REASONING_BUDGET")
struct SDKDefaultReasoningBudgetsTests {
    @Test func isOnByDefaultForSuperAndMiMoAndKillable() {
        let key = "DARKBLOOM_NATIVE_REASONING_BUDGET"
        #expect(SDKFeatureDefaults.reasoningBudgetFamilies == [.nemotronSuper, .mimoV26])
        #expect(NativeReasoningBudget.isEnabled(for: .nemotronSuper, environment: [:], injected: []))
        #expect(NativeReasoningBudget.isEnabled(for: .mimoV26, environment: [:], injected: []))
        // The release's own `1` follows the family list; the operator's `0` kills every family.
        #expect(SDKFeatureDefaults.onByDefault.contains(key))
        #expect(NativeReasoningBudget.isEnabled(for: .mimoV26, environment: [key: "1"], injected: [key]))
        #expect(!NativeReasoningBudget.isEnabled(for: .nemotronSuper, environment: [key: "0"], injected: []))
        #expect(!NativeReasoningBudget.isEnabled(for: .mimoV26, environment: [key: "0"], injected: []))
        #expect(LaunchAgent.passthroughEnvKeys.contains(key))
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [key])?
            .contains("\(key) (mimoV26, nemotronSuper)") == true)
    }
}
