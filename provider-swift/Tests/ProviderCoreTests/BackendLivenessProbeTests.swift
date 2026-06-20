import Testing
@testable import ProviderCore

/// The pure backend-liveness decision (DAR-337/338). Every branch of wedge vs
/// pinned vs healthy is pinned here, GPU-free.
@Suite("Backend liveness policy")
struct BackendLivenessPolicyTests {
    // Small, explicit thresholds so the arithmetic is obvious.
    let policy = BackendLivenessPolicy(
        wedgeStallSeconds: 100, collapsedBudgetTokens: 4096, pinnedSeconds: 60)

    @Test("nothing wrong → healthy")
    func healthyByDefault() {
        let v = policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: nil,
            secondsSinceLastSuccess: 1,
            hasDemand: true)
        #expect(v == .healthy)
    }

    @Test("an admitted request stalled at 0 tokens past the window → wedged")
    func wedgeWhenAdmittedRequestStalls() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: 100,   // == threshold
            budgetCollapsedForSeconds: nil,
            secondsSinceLastSuccess: 0,
            hasDemand: true) == .wedged)
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: 250,   // well past
            budgetCollapsedForSeconds: nil,
            secondsSinceLastSuccess: 0,
            hasDemand: true) == .wedged)
    }

    @Test("a brief 0-token stall below the window is not yet wedged")
    func noWedgeBelowThreshold() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: 99,
            budgetCollapsedForSeconds: nil,
            secondsSinceLastSuccess: 0,
            hasDemand: true) == .healthy)
    }

    @Test("collapsed budget + demand + no recent success past the window → pinned")
    func pinnedWhenBudgetCollapsedWithNoSuccess() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 60,          // == window
            secondsSinceLastSuccess: 60,
            hasDemand: true) == .pinned)
    }

    @Test("never-succeeded (nil last success) counts as no recent success → pinned")
    func pinnedWhenNeverSucceeded() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: nil,
            hasDemand: true) == .pinned)
    }

    @Test("a collapsed budget with NO demand isn't pinned (failing no one)")
    func noPinWithoutDemand() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: nil,
            hasDemand: false) == .healthy)
    }

    @Test("a collapsed budget that is still serving (recent success) isn't pinned")
    func noPinWithRecentSuccess() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: 5,             // < 60 window
            hasDemand: true) == .healthy)
    }

    @Test("a collapse shorter than the window isn't pinned yet")
    func noPinBeforeWindowElapses() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 59,
            secondsSinceLastSuccess: nil,
            hasDemand: true) == .healthy)
    }

    @Test("a budget that isn't collapsed (nil window) isn't pinned")
    func noPinWhenNotCollapsed() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: nil,
            secondsSinceLastSuccess: nil,
            hasDemand: true) == .healthy)
    }

    @Test("wedge takes precedence over a simultaneous pin")
    func wedgePrecedesPin() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: 200,
            budgetCollapsedForSeconds: 200,
            secondsSinceLastSuccess: nil,
            hasDemand: true) == .wedged)
    }

    @Test("the default wedge threshold is the 120s pending-timeout window")
    func defaultWedgeThreshold() {
        #expect(BackendLivenessPolicy.defaultWedgeStallSeconds == 120)
        #expect(BackendLivenessPolicy().wedgeStallSeconds == 120)
    }
}
