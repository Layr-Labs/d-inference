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

    private final class Ticket: @unchecked Sendable {
        let lock = NSLock()
        var starts = 0, ends = 0
        var gate: CheckedContinuation<Void, Never>?
        var endGate: CheckedContinuation<Void, Never>?
    }

    private func makeResidency(
        policy: MiMoV26WiredResidency.Policy, ticket: Ticket, startSucceeds: Bool = true,
        holdStart: Bool = false, endSucceeds: Bool = true, holdEnd: Bool = false
    ) -> GLM5NextWiredResidency {
        GLM5NextWiredResidency(
            policy: policy, policyEntry: UUID(), ceiling: { 1 },
            startTicket: {
                if holdStart {
                    await withCheckedContinuation { continuation in
                        ticket.lock.withLock { ticket.gate = continuation }
                    }
                }
                ticket.lock.withLock { ticket.starts += 1 }
                return startSucceeds
            },
            endTicket: {
                ticket.lock.withLock { ticket.ends += 1 }
                if holdEnd {
                    await withCheckedContinuation { continuation in
                        ticket.lock.withLock { ticket.endGate = continuation }
                    }
                }
                return endSucceeds
            })
    }

    /// An isolated policy instance: the shared production policy is untouched.
    @Test func lifecyclePhasesReleaseExactlyOnce() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let held = makeResidency(policy: policy, ticket: ticket)
        #expect(policy.registeredCount == 1 && held.currentPhase == .prepared)
        await held.start()
        #expect(held.currentPhase == .held)
        await held.end()
        await held.end()
        await held.start()
        #expect(held.currentPhase == .ended && policy.registeredCount == 0)
        #expect(ticket.starts == 1 && ticket.ends == 1)

        let refused = makeResidency(policy: policy, ticket: Ticket(), startSucceeds: false)
        await refused.start()
        #expect(refused.currentPhase == .retainedFault)
        await refused.end()
        #expect(refused.currentPhase == .retainedFault && policy.registeredCount == 1)
    }

    /// `end` during `start` never leaves a ticket held once start returns.
    @Test func endDuringStartReleasesAfterStartReturns() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let residency = makeResidency(policy: policy, ticket: ticket, holdStart: true)
        let starting = Task { await residency.start() }
        while ticket.lock.withLock({ ticket.gate == nil }) { await Task.yield() }
        #expect(residency.currentPhase == .starting)
        #expect(await residency.end() == .pendingStart)
        #expect(residency.currentPhase == .starting && ticket.ends == 0)
        ticket.lock.withLock { ticket.gate }?.resume()
        await starting.value
        #expect(residency.currentPhase == .ended && ticket.ends == 1)
        #expect(policy.registeredCount == 0)
    }

    @Test func unstartedResidencyReleasesItsPolicyEntryOnDeinit() {
        let policy = MiMoV26WiredResidency.Policy()
        do {
            let residency = makeResidency(policy: policy, ticket: Ticket())
            #expect(policy.registeredCount == 1 && residency.currentPhase == .prepared)
        }
        #expect(policy.registeredCount == 0)
    }

    @Test func failedStartCannotReleaseAnUnprovenTicket() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let residency = makeResidency(policy: policy, ticket: ticket, startSucceeds: false)
        await residency.start()
        await residency.end()
        await residency.end()
        #expect(residency.currentPhase != .ended)
        #expect(policy.registeredCount == 1)
        #expect(ticket.starts == 1 && ticket.ends == 0)
    }

    @Test func failedStartWithPendingEndRetainsRegistration() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let residency = makeResidency(
            policy: policy, ticket: ticket, startSucceeds: false, holdStart: true)
        let starting = Task { await residency.start() }
        while ticket.lock.withLock({ ticket.gate == nil }) { await Task.yield() }
        await residency.end()
        ticket.lock.withLock { ticket.gate }?.resume()
        await starting.value
        #expect(residency.currentPhase != .ended)
        #expect(policy.registeredCount == 1)
        #expect(ticket.starts == 1 && ticket.ends == 0)
    }

    @Test func endFaultRetainsTicketAndPolicyWithoutRetry() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let residency = makeResidency(policy: policy, ticket: ticket, endSucceeds: false)
        await residency.start()
        #expect(await residency.end() == .retainedFault)
        #expect(await residency.end() == .retainedFault)
        await residency.start()
        #expect(residency.currentPhase == .retainedFault)
        #expect(policy.registeredCount == 1)
        #expect(ticket.starts == 1 && ticket.ends == 1)
    }

    @Test func concurrentEndCannotClaimCompletionBeforeBackendReturns() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let residency = makeResidency(policy: policy, ticket: ticket, holdEnd: true)
        await residency.start()
        let ending = Task { await residency.end() }
        while ticket.lock.withLock({ ticket.endGate == nil }) { await Task.yield() }
        #expect(await residency.end() == .pendingEnd)
        #expect(residency.currentPhase == .ending && policy.registeredCount == 1)
        ticket.lock.withLock { ticket.endGate }?.resume()
        await residency.waitForSettlement()
        #expect(await ending.value == .ended)
        #expect(await residency.end() == .ended)
        #expect(ticket.starts == 1 && ticket.ends == 1 && policy.registeredCount == 0)
    }

    @Test func pendingEndFaultNeverBecomesCleanRetirement() async {
        let policy = MiMoV26WiredResidency.Policy()
        let ticket = Ticket()
        let residency = makeResidency(
            policy: policy, ticket: ticket, holdStart: true, endSucceeds: false, holdEnd: true)
        let starting = Task { await residency.start() }
        while ticket.lock.withLock({ ticket.gate == nil }) { await Task.yield() }
        #expect(await residency.end() == .pendingStart)
        ticket.lock.withLock { ticket.gate }?.resume()
        while ticket.lock.withLock({ ticket.endGate == nil }) { await Task.yield() }
        #expect(await residency.end() == .pendingEnd)
        #expect(policy.registeredCount == 1)
        ticket.lock.withLock { ticket.endGate }?.resume()
        await residency.waitForSettlement()
        await starting.value
        #expect(await residency.end() == .retainedFault)
        #expect(policy.registeredCount == 1 && ticket.starts == 1 && ticket.ends == 1)
    }

    /// A real ticket on the GPU and the shared policy: exclusive GPU lane only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1"))
    func startHoldsAndEndReleasesTheSharedPolicyEntry() async throws {
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
