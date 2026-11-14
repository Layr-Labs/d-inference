import Testing
@testable import ProviderCore

/// 0.10.13 default flip, scoped to its evidence: `reasoning.max_tokens` budgets
/// are admitted for Nemotron 3.5 Super unless the operator sets `DARKBLOOM_NATIVE_REASONING_BUDGET`
/// (`0` = 0.10.12 for every family, `1` = MiMo too); MiMo keeps 0.10.12's refusal.
@Suite("SDK default: DARKBLOOM_NATIVE_REASONING_BUDGET")
struct SDKDefaultReasoningBudgetsTests {
    @Test func isOnByDefaultForSuperOnlyAndKillable() {
        #expect(SDKFeatureDefaults.reasoningBudgetFamilies == [.nemotronSuper])
        #expect(NativeReasoningBudget.isEnabled(for: .nemotronSuper, environment: [:], injected: []))
        #expect(!NativeReasoningBudget.isEnabled(for: .mimoV26, environment: [:], injected: []))
        // The release's own `1` (set so engines accept budget rows) is not the operator's.
        #expect(SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_NATIVE_REASONING_BUDGET"))
        #expect(!NativeReasoningBudget.isEnabled(for: .mimoV26, environment: ["DARKBLOOM_NATIVE_REASONING_BUDGET": "1"], injected: ["DARKBLOOM_NATIVE_REASONING_BUDGET"]))
        #expect(!NativeReasoningBudget.isEnabled(for: .nemotronSuper, environment: ["DARKBLOOM_NATIVE_REASONING_BUDGET": "0"], injected: []))
        #expect(NativeReasoningBudget.isEnabled(for: .mimoV26, environment: ["DARKBLOOM_NATIVE_REASONING_BUDGET": "1"], injected: []))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_NATIVE_REASONING_BUDGET"))
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: ["DARKBLOOM_NATIVE_REASONING_BUDGET"])?
            .contains("DARKBLOOM_NATIVE_REASONING_BUDGET (nemotronSuper)") == true)
    }
}
