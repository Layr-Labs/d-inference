// Unit tests for `IdleTimeoutPolicy` -- the pure decision function the
// idle-monitor in `ProviderLoop` consults. The actor itself is too
// heavy to spin up in a unit test (Secure Enclave, coordinator,
// security posture), so we keep the rule in a pure helper and pin it
// here.

import Foundation
import Testing
@testable import ProviderCore

@Suite("IdleTimeoutPolicy")
struct IdleTimeoutPolicyTests {

    @Test("unloads when idle elapsed >= timeout, no inflight, model loaded")
    func unloadsWhenAllConditionsMet() {
        #expect(IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(60 * 60),
            timeout: .seconds(60 * 60),
            hasInflight: false,
            hasLoadedModel: true
        ))
        #expect(IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(60 * 90),
            timeout: .seconds(60 * 60),
            hasInflight: false,
            hasLoadedModel: true
        ))
    }

    @Test("does not unload while a request is in flight")
    func neverUnloadsWithInflight() {
        // Even a long idle interval must not evict if a request is still
        // active. Activity-tracking should keep `lastInferenceAt` fresh,
        // but the policy must be defensive against stale timestamps too.
        #expect(!IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(60 * 60 * 24),
            timeout: .seconds(60 * 60),
            hasInflight: true,
            hasLoadedModel: true
        ))
    }

    @Test("does not unload when no model is loaded")
    func neverUnloadsWithNoModel() {
        #expect(!IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(60 * 60 * 10),
            timeout: .seconds(60 * 60),
            hasInflight: false,
            hasLoadedModel: false
        ))
    }

    @Test("does not unload before the timeout has elapsed")
    func waitsForTimeout() {
        #expect(!IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(59 * 60),
            timeout: .seconds(60 * 60),
            hasInflight: false,
            hasLoadedModel: true
        ))
        #expect(!IdleTimeoutPolicy.shouldUnload(
            elapsed: .zero,
            timeout: .seconds(60 * 60),
            hasInflight: false,
            hasLoadedModel: true
        ))
    }

    @Test("zero timeout still requires no inflight + model loaded")
    func zeroTimeoutEdgeCase() {
        // With timeout==0 the monitor would unload immediately on every
        // tick. ProviderLoop disables the monitor entirely when
        // idleTimeoutMins==0, so this branch is unreachable in
        // production -- but the policy itself stays defensive.
        #expect(IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(1),
            timeout: .zero,
            hasInflight: false,
            hasLoadedModel: true
        ))
        #expect(!IdleTimeoutPolicy.shouldUnload(
            elapsed: .seconds(1),
            timeout: .zero,
            hasInflight: true,
            hasLoadedModel: true
        ))
    }
}
