import Testing
@testable import ProviderCore

/// The pure backend-liveness decision. Every branch of wedge vs pinned vs
/// healthy is pinned here, GPU-free.
@Suite("Backend liveness policy")
struct BackendLivenessPolicyTests {
    // Small, explicit thresholds so the arithmetic is obvious. The reject-demand
    // window (30) is deliberately distinct from the pinned window (60) so the two
    // can't be conflated by accident.
    let policy = BackendLivenessPolicy(
        wedgeStallSeconds: 100, collapsedBudgetTokens: 4096, pinnedSeconds: 60,
        admissionRejectDemandSeconds: 30)

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

    // MARK: - Admission-reject demand (the pinned-pool-with-no-bridges bug)

    @Test("KEY REGRESSION: collapsed budget + recent admission reject but ZERO active bridges → pinned")
    func pinnedWhenRecentRejectWithNoBridges() {
        // The exact bug this fix targets. When the global KV budget collapses to
        // the floor, every real request's promptTokens+maxTokens exceeds it and is
        // rejected at the EARLY token-budget guard in submit()/submitTokenized()
        // BEFORE any bridge is inserted. So on every watchdog tick activeBridges
        // and pending are empty → hasDemand:false. Pre-fix the policy could never
        // see demand and never returned .pinned, so the engine never self-restarted
        // and the node 503'd "token_budget_exhausted" forever. The recent
        // admission reject is the demand signal that breaks that deadlock.
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,       // no admitted request (none got in)
            budgetCollapsedForSeconds: 60,              // == pinned window
            secondsSinceLastSuccess: nil,               // never succeeded since load
            hasDemand: false,                           // 0 active bridges, 0 pending
            secondsSinceLastAdmissionReject: 1) == .pinned)
    }

    @Test("a reject exactly at the demand-window edge still counts as demand → pinned")
    func pinnedWhenRejectAtWindowEdge() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: 120,
            hasDemand: false,
            secondsSinceLastAdmissionReject: 30) == .pinned)   // == admissionRejectDemandSeconds
    }

    @Test("a reject older than the demand window is no longer current demand → healthy")
    func noPinWhenRejectOlderThanWindow() {
        // One reject then silence: the box isn't actively failing anyone now, so a
        // momentarily collapsed budget must not trigger a restart.
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: nil,
            hasDemand: false,
            secondsSinceLastAdmissionReject: 31) == .healthy)  // just past the 30s window
    }

    @Test("a recent reject on a NOT-collapsed budget isn't pinned (an oversized request on a healthy box)")
    func noPinWhenRejectButBudgetHealthy() {
        // The early guard also rejects a single huge request on a perfectly healthy
        // box. The collapse gate (nil window here) must keep that from being a pin.
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: nil,             // budget is fine
            secondsSinceLastSuccess: nil,
            hasDemand: false,
            secondsSinceLastAdmissionReject: 1) == .healthy)
    }

    @Test("a recent reject + collapsed budget but a RECENT success isn't pinned (still serving)")
    func noPinWhenRejectButRecentSuccess() {
        // A busy box near capacity can reject a big request yet still be decoding
        // others. A recent success means it is not pinned.
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: 5,                 // < 60 pinned window
            hasDemand: false,
            secondsSinceLastAdmissionReject: 1) == .healthy)
    }

    @Test("no reject signal (nil) and no bridges stays healthy even when collapsed (backward-compat)")
    func noPinWhenNoRejectAndNoBridges() {
        // The pre-fix behavior for a genuinely idle box with a collapsed budget:
        // failing no one, so not a restart trigger.
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: nil,
            hasDemand: false,
            secondsSinceLastAdmissionReject: nil) == .healthy)
    }

    @Test("active-bridge demand alone still pins without any reject signal (existing path intact)")
    func pinnedFromBridgeDemandWithoutReject() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: nil,
            budgetCollapsedForSeconds: 120,
            secondsSinceLastSuccess: nil,
            hasDemand: true,                            // active/queued work
            secondsSinceLastAdmissionReject: nil) == .pinned)
    }

    @Test("a wedge still wins even when the demand came from a reject")
    func wedgePrecedesPinFromReject() {
        #expect(policy.assess(
            longestAdmittedZeroTokenSeconds: 200,       // stalled admitted request
            budgetCollapsedForSeconds: 200,
            secondsSinceLastSuccess: nil,
            hasDemand: false,
            secondsSinceLastAdmissionReject: 1) == .wedged)
    }

    @Test("the default admission-reject demand window is 60s")
    func defaultAdmissionRejectDemandWindow() {
        #expect(BackendLivenessPolicy.defaultAdmissionRejectDemandSeconds == 60)
        #expect(BackendLivenessPolicy().admissionRejectDemandSeconds == 60)
    }
}
