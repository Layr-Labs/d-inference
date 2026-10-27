import Foundation

/// Pure CPU controls only. Fake allocators below test the inequality and call
/// granularity; none of their values are reported as real MLX allocation bounds.
@main enum DeltaPlanningChecks {
    struct Failure: Error { let reason: String }
    static let scope = String(repeating: "a", count: 64)
    static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure(reason: reason) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(reason: "expected refusal")
    }
    static func envelope(_ prompt: Int = 4096, _ outputs: Int = 128) throws -> Gemma4MTPDeltaEnvelope {
        try .init(scopeSHA256: scope, promptTokens: prompt, outputCount: outputs)
    }
    static func snapshot(_ env: Gemma4MTPDeltaEnvelope, _ ordinal: UInt64 = 0,
                         _ frontier: Int? = nil, _ dtype: Int = 3) throws -> Gemma4MTPDeltaSnapshot {
        try .init(envelope: env, ordinal: ordinal, frontier: frontier ?? env.initialFrontier,
                  seed: 17, hiddenDType: dtype)
    }
    static func plan(_ env: Gemma4MTPDeltaEnvelope) throws -> Gemma4MTPDeltaAllocationPlan {
        let base = try snapshot(env)
        let next = try snapshot(env, 1, env.maximumReseedFrontier)
        return try .init(envelope: env, descriptor: .init(envelope: env, base: base, next: next))
    }
    static func reservation(_ plan: Gemma4MTPDeltaAllocationPlan,
                            _ bound: (Int) -> Int) -> [Gemma4MTPDeltaAllocationPlan.ReservedTerm] {
        plan.expectedOriginalSnapshotTerms.map {
            .init(name: $0.name, logicalBytes: $0.logicalBytes, allocationBound: bound($0.logicalBytes))
        }
    }
    static func active(_ env: Gemma4MTPDeltaEnvelope) throws -> Gemma4MTPConditioningMirrorPlan {
        var state = Gemma4MTPConditioningMirrorPlan(envelope: env)
        let initial = try snapshot(env)
        try state.beginFullInitialSeed(initial)
        try state.recordInstalledAfterNativeFence(initial)
        try state.recordExactSeedACKCompleted(initial)
        return state
    }
    static func ready(_ env: Gemma4MTPDeltaEnvelope) throws -> Gemma4MTPConditioningMirrorPlan {
        var state = try active(env)
        let initial = try snapshot(env)
        try state.beginBranchRetirement(initial, outstandingGrants: 0, verificationWindowOpen: false)
        try state.recordFencedBranchRetirement(initial, disposition: .branchRetiredMirrorRetainedV2)
        return state
    }

    static func main() throws {
        var passed: [String] = []
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }
        try test("boundedO16AndO128Frontiers") {
            for prompt in [128, 4096, 8192] {
                for outputs in [16, 128] {
                    let env = try envelope(prompt, outputs), value = try plan(env)
                    try require(value.descriptor.appended.count == outputs - 4, "reseed gap")
                    try require(env.maximumFrontier == prompt + outputs - 1, "terminal frontier")
                    try require(value.received.count == 5 && value.received.allSatisfy {
                        $0.logicalBytes <= 16 * 1024 * 1024
                    }, "bounded transfers")
                }
            }
        }
        try test("rejectsUnboundEnvelopeAndHiddenType") {
            try refuses { _ = try Gemma4MTPDeltaEnvelope(scopeSHA256: "a", promptTokens: 128, outputCount: 16) }
            try refuses { _ = try envelope(8193) }
            try refuses { _ = try envelope(4096, 129) }
            try refuses { _ = try snapshot(envelope(), 0, nil, 4) }
        }
        try test("slidingOverlapPreservesChronologicalRange") {
            let env = try envelope(1022), base = try snapshot(env)
            let next = try snapshot(env, 1, 1031)
            let value = try Gemma4MTPDeltaDescriptor(envelope: env, base: base, next: next)
            try require(value.oldSliding == 0..<1023 && value.newSliding == 7..<1031, "window ranges")
            try require(value.retainedSliding == 7..<1023 && value.appended == 1023..<1031, "exact reconstruction")
            let indices = Array(value.retainedSliding) + Array(value.appended)
            try require(indices == Array(value.newSliding), "no duplicate/missing positions")
        }
        try test("longContextOverlapAndMaximumDelta") {
            let value = try plan(envelope())
            try require(value.descriptor.retainedSliding == 3197..<4097, "old retained window")
            try require(value.descriptor.appended == 4097..<4221, "new suffix")
            try require(try value.tensorBytes == 1_534_976, "actual logical tensor sum")
            try require(try value.logicalLiveBytes == 52_382_720, "actual logical live sum")
        }
        try test("eachDTypeHasExactHiddenBytes") {
            let env = try envelope()
            for dtype in 1...3 {
                let value = try Gemma4MTPDeltaAllocationPlan(envelope: env, descriptor: .init(
                    envelope: env, base: snapshot(env, 0, nil, dtype), next: snapshot(env, 1, 4098, dtype)))
                try require(value.received[0].logicalBytes == (dtype == 3 ? 11_264 : 5_632), "hidden bytes")
            }
        }
        try test("rejectsRollbackDuplicateSkippedOrdinalAndTypeChange") {
            let env = try envelope(), base = try snapshot(env)
            for next in [try snapshot(env, 1), try snapshot(env, 2, 4098), try snapshot(env, 1, 4098, 1)] {
                try refuses { _ = try Gemma4MTPDeltaDescriptor(envelope: env, base: base, next: next) }
            }
            let later = try snapshot(env, 1, 4100), rollback = try snapshot(env, 2, 4099)
            try refuses { _ = try Gemma4MTPDeltaDescriptor(envelope: env, base: later, next: rollback) }
        }
        try test("rejectsForeignScopeAndOversizedReseed") {
            let env = try envelope(), base = try snapshot(env)
            let foreign = try Gemma4MTPDeltaEnvelope(scopeSHA256: String(repeating: "b", count: 64), promptTokens: 4096, outputCount: 128)
            let next = try snapshot(foreign, 1, 4098)
            try refuses { _ = try Gemma4MTPDeltaDescriptor(envelope: env, base: base, next: next) }
            try refuses { _ = try snapshot(env, 1, env.maximumReseedFrontier + 1) }
        }
        try test("canonicalDescriptorBindsBaseAndNext") {
            let env = try envelope(), base = try snapshot(env)
            let one = try Gemma4MTPDeltaDescriptor(envelope: env, base: base, next: snapshot(env, 1, 4098))
            let two = try Gemma4MTPDeltaDescriptor(envelope: env, base: base, next: snapshot(env, 1, 4099))
            try require(one.canonicalBytes != two.canonicalBytes, "frontier binding")
            try require(String(decoding: one.canonicalBytes, as: UTF8.self).hasPrefix("gemma4_mtp_conditioning_delta_v2\n"), "separate version")
        }
        try test("thirteenSeparateAllocationCallsUseOriginalTwelveTerms") {
            let value = try plan(envelope())
            func bound(_ n: Int) -> Int { ((n + 16_383) / 16_384) * 16_384 }
            var inputs: [Int] = []
            let result = try value.admit(originalSnapshotTerms: reservation(value, bound)) { n in inputs.append(n); return bound(n) }
            try require(inputs == value.expectedOriginalSnapshotTerms.map(\.logicalBytes) + value.roots.map(\.logicalBytes), "per-array allocator inputs")
            try require(result.roots.count == 13 && result.originalSnapshotTerms.count == 12, "root accounting")
            try require(result.requiredBytes <= result.reservedBytes, "admission inequality")
        }
        try test("nonlinearAllocatorCanRefuseDespiteLogicalSlack") {
            let value = try plan(envelope())
            func bound(_ n: Int) -> Int { n + 64 * 1024 * 1024 }
            try refuses { _ = try value.admit(originalSnapshotTerms: reservation(value, bound), allocationBound: bound) }
        }
        try test("rejectsMissingDuplicateAndAlteredReservation") {
            let value = try plan(envelope()), saved = reservation(value, { $0 })
            try refuses { _ = try value.admit(originalSnapshotTerms: Array(saved.dropLast()), allocationBound: { $0 }) }
            var duplicate = saved; duplicate[1] = saved[0]
            try refuses { _ = try value.admit(originalSnapshotTerms: duplicate, allocationBound: { $0 }) }
            var altered = saved; altered[0] = .init(name: saved[0].name, logicalBytes: saved[0].logicalBytes, allocationBound: saved[0].allocationBound + 1)
            try refuses { _ = try value.admit(originalSnapshotTerms: altered, allocationBound: { $0 }) }
        }
        try test("rejectsAllocatorUnderboundAndCheckedOverflow") {
            let value = try plan(envelope())
            try refuses { _ = try value.admit(originalSnapshotTerms: reservation(value, { $0 }), allocationBound: { $0 - 1 }) }
            try refuses { _ = try value.admit(originalSnapshotTerms: reservation(value, { _ in Int.max }), allocationBound: { _ in Int.max }) }
            try refuses { _ = try Gemma4MTPDeltaBytes.product([Int.max, 2]) }
        }
        try test("deltaRequiresFullInitialSeedAndExactACK") {
            let env = try envelope(), value = try plan(env)
            var state = Gemma4MTPConditioningMirrorPlan(envelope: env)
            try refuses { _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier) }
            try require(state.phase == .poisoned && state.installed == nil, "no invented base")
            state = .init(envelope: env)
            let initial = try snapshot(env)
            try state.beginFullInitialSeed(initial)
            try require(state.installed == nil && state.newStagingRootObligations == 9, "unacknowledged seed")
            try refuses { try state.recordExactSeedACKCompleted(initial) }
            try require(state.newStagingRootObligations == 9, "failed seed retained")
        }
        try test("branchRetirementRefusesOutstandingWork") {
            let env = try envelope(), initial = try snapshot(env)
            var grant = try active(env), window = try active(env)
            try refuses { try grant.beginBranchRetirement(initial, outstandingGrants: 1, verificationWindowOpen: false) }
            try refuses { try window.beginBranchRetirement(initial, outstandingGrants: 0, verificationWindowOpen: true) }
            try require(grant.oldMirrorRootObligations == 4 && window.oldMirrorRootObligations == 4, "mirror retained after refusal")
        }
        try test("v1RetirementCannotAuthorizeRetainedMirror") {
            let env = try envelope(), initial = try snapshot(env)
            var state = try active(env)
            try state.beginBranchRetirement(initial, outstandingGrants: 0, verificationWindowOpen: false)
            try refuses { try state.recordFencedBranchRetirement(initial, disposition: .allRootsRetiredV1) }
            try require(state.phase == .poisoned && state.oldMirrorRootObligations == 4, "explicit disposition")
        }
        try test("deltaInstallRetainsOldAndNewThroughACK") {
            let env = try envelope(), value = try plan(env)
            var state = try ready(env)
            _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier)
            try require(state.oldMirrorRootObligations == 4 && state.newStagingRootObligations == 9, "13 roots")
            try state.recordInstalledAfterNativeFence(value.descriptor.next)
            try require(state.installed == value.descriptor.base && state.pending == value.descriptor.next, "base not advanced before ACK")
            try state.recordExactSeedACKCompleted(value.descriptor.next)
            try require(state.installed == value.descriptor.next && state.pending == nil && state.newStagingRootObligations == 0, "promotion after ACK")
        }
        try test("wrongBaseAndTargetFrontierPoisonWithoutDroppingMirror") {
            let env = try envelope(), value = try plan(env)
            var state = try ready(env)
            try refuses { _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier - 1) }
            try require(state.installed == value.descriptor.base && state.oldMirrorRootObligations == 4, "retain on mismatch")
            state = try ready(env)
            let base = try snapshot(env, 1, 4098), next = try snapshot(env, 2, 4099)
            let foreignBase = try Gemma4MTPDeltaDescriptor(envelope: env, base: base, next: next)
            try refuses { _ = try state.beginDelta(foreignBase, committedTargetFrontier: next.frontier) }
        }
        try test("successiveDeltasRequireLatestAcknowledgedBase") {
            let env = try envelope()
            var state = try ready(env)
            let first = try Gemma4MTPDeltaDescriptor(envelope: env, base: snapshot(env), next: snapshot(env, 1, 4099))
            _ = try state.beginDelta(first, committedTargetFrontier: 4099)
            try state.recordInstalledAfterNativeFence(first.next)
            try state.recordExactSeedACKCompleted(first.next)
            try state.beginBranchRetirement(first.next, outstandingGrants: 0, verificationWindowOpen: false)
            try state.recordFencedBranchRetirement(first.next, disposition: .branchRetiredMirrorRetainedV2)
            let second = try Gemma4MTPDeltaDescriptor(envelope: env, base: first.next, next: snapshot(env, 2, 4107))
            _ = try state.beginDelta(second, committedTargetFrontier: 4107)
            try state.recordInstalledAfterNativeFence(second.next)
            try state.recordExactSeedACKCompleted(second.next)
            try require(state.installed == second.next, "latest base")
            try refuses { try state.recordExactSeedACKCompleted(second.next) }
            try require(state.installed == second.next && state.oldMirrorRootObligations == 4, "replayed ACK never discards mirror")
        }
        try test("failedACKOrFenceRetainsAllThirteenAndRejectsReplay") {
            let env = try envelope(), value = try plan(env)
            var state = try ready(env)
            _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier)
            state.poison() // Runtime reports a failed native fence; no completion event.
            try require(state.oldMirrorRootObligations + state.newStagingRootObligations == 13, "failed fence retention")
            try refuses { try state.recordInstalledAfterNativeFence(value.descriptor.next) }
            state = try ready(env)
            _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier)
            try state.recordInstalledAfterNativeFence(value.descriptor.next)
            try refuses { try state.recordExactSeedACKCompleted(value.descriptor.base) }
            try require(state.oldMirrorRootObligations + state.newStagingRootObligations == 13, "wrong ACK retention")
            try refuses { _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier) }
        }
        try test("onlyOriginalCleanupEventClearsFailureObligations") {
            let env = try envelope(), value = try plan(env)
            var state = try ready(env)
            _ = try state.beginDelta(value.descriptor, committedTargetFrontier: value.descriptor.next.frontier)
            state.poison()
            try refuses { try state.recordOriginalOwnerCleanupCompleted(scopeSHA256: String(repeating: "b", count: 64)) }
            try require(state.newStagingRootObligations == 9, "foreign cleanup refused")
            try state.recordOriginalOwnerCleanupCompleted(scopeSHA256: scope)
            try require(state.phase == .closed && state.oldMirrorRootObligations == 0 && state.newStagingRootObligations == 0, "terminal cleanup")
            try refuses { try state.recordOriginalOwnerCleanupCompleted(scopeSHA256: scope) }
            try require(state.phase == .closed, "terminal state cannot reopen")
        }
        let data = try JSONSerialization.data(withJSONObject: ["schema": "gemma4_mtp_delta_planning_checks_v1", "passed": passed, "nativeExecuted": false, "gpuExecuted": false], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
