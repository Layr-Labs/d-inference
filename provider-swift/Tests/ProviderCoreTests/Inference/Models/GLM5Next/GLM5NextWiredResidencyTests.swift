// Copyright © 2026 Eigen Labs.
// Host lifecycle tests; not full-model qualification.
import Foundation
import MLX
import Testing
@testable import ProviderCore

@Suite(.serialized)
struct GLM5NextWiredResidencyTests {
    @Test func defaultOnWithMiMoRollbackSpellings() {
        let flag = GLM5NextWiredResidency.environmentFlag
        #expect(GLM5NextWiredResidency.isEnabled(environment: [:]))
        #expect(GLM5NextWiredResidency.isEnabled(environment: [flag: "1"]))
        #expect(GLM5NextWiredResidency.isEnabled(environment: [flag: "true"]))
        for rollback in ["0", "false", " NO ", "Off"] {
            #expect(!GLM5NextWiredResidency.isEnabled(environment: [flag: rollback]), "\(rollback)")
        }
        // The MiMo flag does not roll back GLM.
        #expect(GLM5NextWiredResidency.isEnabled(
            environment: [MiMoV26WiredResidency.environmentFlag: "0"]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(flag))
    }

    @Test func disabledPreparesNothing() {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0)
        #expect(GLM5NextWiredResidency.prepare(budget: budget, enabled: false) == nil)
    }

    /// A real ticket on the GPU: held after start, removed from the shared
    /// policy after end, and end is idempotent.
    @Test func startHoldsAndEndReleasesTheSharedPolicyEntry() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0)
        let policy = MiMoV26WiredResidency.Policy.shared
        let before = policy.registeredCount
        let residency = try #require(GLM5NextWiredResidency.prepare(budget: budget, enabled: true))
        #expect(policy.registeredCount == before + 1)
        #expect(residency.currentPhase == .prepared)
        await residency.start()
        #expect(residency.currentPhase == .held)
        await residency.end()
        #expect(residency.currentPhase == .ended)
        #expect(policy.registeredCount == before)
        await residency.end()
        await residency.start()
        #expect(residency.currentPhase == .ended)
        #expect(policy.registeredCount == before)
    }
}
