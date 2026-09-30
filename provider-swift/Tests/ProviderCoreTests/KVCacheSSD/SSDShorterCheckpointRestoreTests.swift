import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Baseline-compiling oracles: the PR23 reader tries only the largest endpoint.
/// No new production API, retry hook, changed capture cap or precision is used.
@Suite("Bounded shorter complete-checkpoint restore on CPU", .serialized)
struct SSDShorterCheckpointRestoreTests {
    @Test("typed plan capacity tries one authenticated shorter endpoint")
    func typedPlanCapacityFallsBack() async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let expected = try SSDShorterRestoreFixture.expectedReadBytes(fixture, store: store, failed: [512], success: 256)
            let epoch = store.config.epochStore?.current
            let result = await store.stage(requestID: .init(900), request: fixture.request(),
                reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                    probe.record(manifest.position)
                    if manifest.position == 512 { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                    #expect(fixture.codec.admission.bytesReserved == CBv2CompleteCheckpointManifest.maximumProviderScratchBytes)
                    #expect(store.stats().stagedBytesInUse == SSDHybridCheckpointStore.ioScratchBytes)
                    #expect(probe.scratchCounts.1 == 1, "first attempt scratch must retire before another plan")
                    return try probe.cpuPlan(manifest, fixture: fixture)
                }
            #expect(probe.positions == [512, 256])
            #expect(probe.scratchCounts.0 == 2 && probe.scratchCounts.1 == 2)
            #expect(result.stagedTokens == 256)
            SSDShorterRestoreFixture.expectSingleStage(store, result: result, readBytes: expected, files: 3)
            #expect(store.config.epochStore?.current == epoch && store.stats().entries == 2 && store.stats().corruptDropped == 0)
            if result.staged { try SSDShorterRestoreFixture.adoptAndRetire(fixture, store: store, requestID: .init(900), position: 256) }
        }
    }

    @Test("real shared-paged admission refusal unwinds before the shorter allocation")
    func nativeAdmissionCapacityFallsBack() async throws {
        try await SSDShorterRestoreFixture.withStore(shared: true) { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let expected = try SSDShorterRestoreFixture.expectedReadBytes(fixture, store: store, failed: [512], success: 256)
            let result = await store.stage(requestID: .init(901), request: fixture.request(),
                reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                    probe.record(manifest.position)
                    #expect(fixture.codec.admission.bytesReserved == 0, "old plan/pressure metadata must have unwound")
                    #expect(store.stats().stagedBytesInUse == SSDHybridCheckpointStore.ioScratchBytes)
                    let plan = try probe.cpuPlan(manifest, fixture: fixture)
                    if manifest.position == 512 {
                        // A separately owned transient competitor makes the real
                        // reserveCheckpointStage throw capacityExhausted, before
                        // native allocation. Its lifetime is tied to this plan;
                        // only actual failed-plan unwind releases it. No cap moves.
                        let required = plan.nativeDestinationBytes + plan.scratchBytes
                        let pressureBytes = fixture.codec.admission.bytesCapacity - fixture.codec.admission.bytesReserved - required + 1
                        try #require(pressureBytes > 0)
                        let pressure = try fixture.codec.admission.reserveTransient(bytes: pressureBytes)
                        #expect(fixture.codec.admission.bytesCapacity - fixture.codec.admission.bytesReserved == required - 1)
                        plan.evaluateDestinations = { arrays in
                            withExtendedLifetime(pressure) {
                                probe.evaluated(512)
                                Issue.record("largest destination reached allocation despite typed admission refusal")
                                Device.withDefaultDevice(.cpu) { eval(arrays) }
                            }
                        }
                    } else { #expect(probe.scratchCounts.1 == 1) }
                    return plan
                }
            #expect(probe.positions == [512, 256])
            #expect(!probe.evaluatedPositions.contains(512) && probe.evaluatedPositions.contains(256))
            #expect(probe.scratchCounts.0 == 2 && probe.scratchCounts.1 == 2)
            #expect(result.stagedTokens == 256)
            SSDShorterRestoreFixture.expectSingleStage(store, result: result, readBytes: expected, files: 3)
            #expect(store.stats().stagedBytesInUse == 0, "successful shared stage has already refunded provider host IO")
            if result.staged { try SSDShorterRestoreFixture.adoptAndRetire(fixture, store: store, requestID: .init(901), position: 256) }
        }
    }

    @Test("provider destination budget admits the shorter peak without overlapping charges")
    func destinationBudgetFallsBack() async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, donor in
            func peak(_ position: Int) throws -> Int {
                let plan = try fixture.plan(fixture.manifest(position: position))
                return SSDHybridCheckpointStore.ioScratchBytes + plan.nativeDestinationBytes + plan.scratchBytes
            }
            let shortPeak = try peak(256), longPeak = try peak(512)
            try #require(shortPeak < longPeak)
            #expect(fixture.codec.admission.bytesReserved == 0)
            await donor.closeAndWait()
            let total = UInt64(2 << 30) + UInt64(shortPeak)
            let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
                memorySnapshot: { .init(total: total, active: 0, cache: 0, systemAvailable: .max) })
            let store = SSDHybridCheckpointStore(config: donor.config, kekKey: fixture.key, kvBudget: budget,
                diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
            store.scanOnDisk()
            let probe = SSDShorterRestoreProbe()
            do {
                let expected = try SSDShorterRestoreFixture.expectedReadBytes(fixture, store: store, failed: [512], success: 256)
                let result = await store.stage(requestID: .init(902), request: fixture.request(),
                    reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                        probe.record(manifest.position)
                        #expect(store.stats().stagedBytesInUse == SSDHybridCheckpointStore.ioScratchBytes)
                        #expect(budget.processLedger.snapshot().chargedBytes == UInt64(SSDHybridCheckpointStore.ioScratchBytes))
                        if manifest.position == 256 { #expect(probe.scratchCounts.1 == 1) }
                        return try probe.cpuPlan(manifest, fixture: fixture)
                    }
                #expect(probe.positions == [512, 256])
                #expect(!probe.evaluatedPositions.contains(512) && probe.evaluatedPositions.contains(256))
                #expect(result.stagedTokens == 256)
                SSDShorterRestoreFixture.expectSingleStage(store, result: result, readBytes: expected, files: 3)
                #expect(store.stats().peakStagingReservationBytes <= shortPeak)
                if result.staged { try SSDShorterRestoreFixture.adoptAndRetire(fixture, store: store, requestID: .init(902), position: 256) }
            } catch { await store.closeAndWait(); throw error }
            await store.closeAndWait()
            #expect(await budget.outstandingReservedBytes() == 0)
            #expect(budget.processLedger.snapshot().chargedBytes == 0 && budget.processLedger.snapshot().ownerCount == 0)
        }
    }

    @Test("a second capacity refusal stops without trying a third valid endpoint")
    func retryIsBoundedToOne() async throws {
        try await SSDShorterRestoreFixture.withStore(positions: [256, 512, 768]) { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let expected = try SSDShorterRestoreFixture.expectedReadBytes(fixture, store: store, failed: [768, 512], success: nil)
            let result = await store.stage(requestID: .init(903), request: fixture.request(),
                reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                    probe.record(manifest.position)
                    if manifest.position > 256 { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                    Issue.record("a third candidate exceeded the one-retry contract")
                    return try probe.cpuPlan(manifest, fixture: fixture)
                }
            #expect(probe.positions == [768, 512])
            #expect(result.disposition == .skippedCapacity)
            #expect(probe.scratchCounts.0 == 2 && probe.scratchCounts.1 == 2)
            SSDShorterRestoreFixture.expectSingleStage(store, result: result, readBytes: expected, files: 2)
            #expect(store.stats().entries == 3 && store.stats().corruptDropped == 0)
        }
    }

    @Test("generic allocation and policy faults are not shorter-retry signals", arguments: ["allocation", "policy", "scratch"])
    func nonCapacityFaultsStayCold(_ fault: String) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let result = await store.stage(requestID: .init(904), request: fixture.request(), reserveReadScratch: {
                if fault == "scratch" { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                return try probe.scratch(fixture)
            }) { manifest in
                probe.record(manifest.position)
                if fault == "policy" { throw CBv2KVError.backendIneligible(reason: "synthetic policy rejection") }
                let plan = try probe.cpuPlan(manifest, fixture: fixture)
                plan.evaluateDestinations = { _ in throw CBv2CompleteCheckpointError.allocationFailed }
                return plan
            }
            #expect(probe.positions == (fault == "scratch" ? [] : [512]))
            #expect(result.disposition == (fault == "policy" ? .skippedPolicy : .skippedCapacity))
            #expect(store.stats().filesRead == (fault == "scratch" ? 0 : 1))
            #expect(store.stats().entries == 2 && store.stats().corruptDropped == 0)
            #expect(!result.staged && result.resolved(actualCachedTokens: 0).cachedTokens == 0)
        }
    }

    @Test("corruption never authorizes retry or partial shorter publication", arguments: ["largest", "shorter"])
    func corruptCandidateStaysCold(_ target: String) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let corruptPosition = target == "largest" ? 512 : 256
            let file = fixture.file(store, position: corruptPosition)
            var ciphertext = try Data(contentsOf: file)
            ciphertext[ciphertext.count - 1] ^= 1
            try ciphertext.write(to: file)
            let result = await store.stage(requestID: .init(907), request: fixture.request(),
                reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                    probe.record(manifest.position)
                    if target == "shorter" && manifest.position == 512 {
                        throw CBv2KVError.capacityExhausted(needed: 2, available: 1)
                    }
                    return try probe.cpuPlan(manifest, fixture: fixture)
                }
            #expect(probe.positions == (target == "largest" ? [512] : [512, 256]))
            #expect(result.disposition == .missCorrupt && !result.staged)
            #expect(store.stats().filesRead == (target == "largest" ? 2 : 3) && store.stats().corruptDropped == 1)
            #expect(store.stats().entries == 1 && store.stats().stageConsumptions == 0)
            #expect(FileManager.default.fileExists(atPath: fixture.file(store, position: target == "largest" ? 256 : 512).path))
        }
    }

    @Test("invalidated first-attempt registration cannot be recreated for fallback",
          arguments: ["complete", "close", "epoch", "cancel"])
    func invalidationBeforeRetryStaysCold(_ action: String) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let task = Task {
                await store.stage(requestID: .init(905), request: fixture.request(),
                    reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                        probe.record(manifest.position)
                        switch action {
                        case "complete": store.completeStaging(requestID: .init(905))
                        case "close": store.close()
                        case "epoch": #expect(store.config.epochStore?.rotate() != nil)
                        default: withUnsafeCurrentTask { $0?.cancel() }
                        }
                        throw CBv2KVError.capacityExhausted(needed: 2, available: 1)
                    }
            }
            let result = await task.value
            #expect(probe.positions == [512])
            #expect(result.disposition == .skippedPolicy)
            #expect(store.stats().filesRead == 1 && store.stats().corruptDropped == 0)
            #expect(store.takeStaged(requestID: .init(905), tokens: fixture.tokens,
                cacheSalt: "tenant-a", maximumSequenceLength: fixture.tokens.count + 8) == nil)
        }
    }

    @Test("first scratch retirement is not an unregistered gap that can resurrect work",
          arguments: ["complete", "close", "epoch", "cancel"])
    func retirementBoundaryKeepsLogicalRegistration(_ action: String) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let task = Task {
                await store.stage(requestID: .init(910), request: fixture.request(), reserveReadScratch: {
                    try probe.scratch(fixture, onRelease: { count in
                        guard count == 1 else { return }
                        switch action {
                        case "complete": store.completeStaging(requestID: .init(910))
                        case "close": store.close()
                        case "epoch": #expect(store.config.epochStore?.rotate() != nil)
                        default: withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
                }) { manifest in
                    probe.record(manifest.position)
                    if manifest.position == 512 { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                    return try probe.cpuPlan(manifest, fixture: fixture)
                }
            }
            let result = await task.value
            #expect(probe.positions == [512] && probe.scratchCounts.0 == 1 && probe.scratchCounts.1 == 1)
            #expect(result.disposition == .skippedPolicy && store.stats().filesRead == 1)
            #expect(store.lock.withLock { store.stages.isEmpty && store.authenticatedReceipts.isEmpty })
        }
    }

    @Test("same-ID replacement owns its registration while the old attempt unwinds")
    func sameIDReplacementCannotBeErasedOrRetryAsOldWork() async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let gate = SSDShorterRestoreGate()
            defer { gate.open() }
            let oldProbe = SSDShorterRestoreProbe(), newProbe = SSDShorterRestoreProbe()
            let id = CBv2RequestID(908)
            let old = Task {
                await store.stage(requestID: id, request: fixture.request(),
                    reserveReadScratch: { try oldProbe.scratch(fixture) }) { manifest in
                        oldProbe.record(manifest.position)
                        gate.block()
                        throw CBv2KVError.capacityExhausted(needed: 2, available: 1)
                    }
            }
            guard await gate.waitUntilEntered() else {
                Issue.record("old read did not reach its authenticated-plan barrier")
                old.cancel(); store.close(); gate.open()
                _ = await old.value
                return
            }
            store.completeStaging(requestID: id)
            let replacement = Task {
                await store.stage(requestID: id, request: fixture.request(),
                    reserveReadScratch: { try newProbe.scratch(fixture) }) { manifest in
                        newProbe.record(manifest.position)
                        return try newProbe.cpuPlan(manifest, fixture: fixture)
                    }
            }
            let registered = await SSDShorterRestoreGate.waitUntil {
                store.fileCoordinator.pendingCount(for: fixture.file(store, position: 512)) == 1
            }
            guard registered else {
                Issue.record("replacement did not register behind the exact first-file lease")
                old.cancel(); replacement.cancel(); store.close(); gate.open()
                _ = await old.value; _ = await replacement.value
                return
            }
            gate.open()
            let oldResult = await old.value, newResult = await replacement.value
            #expect(oldResult.disposition == .skippedPolicy && oldProbe.positions == [512])
            #expect(newResult.stagedTokens == 512 && newProbe.positions == [512])
            #expect(store.lock.withLock { store.reading.isEmpty && store.stages.count == 1 })
            #expect(store.stats().stageMilliseconds == oldResult.stageMs + newResult.stageMs)
            #expect(store.fileCoordinator.pendingCount(for: fixture.file(store, position: 512)) == 0)
            if newResult.staged { try SSDShorterRestoreFixture.adoptAndRetire(fixture, store: store, requestID: id, position: 512) }
        }
    }

    @Test("invalidation while the shorter exact-file access waits cannot publish",
          arguments: ["complete", "close", "epoch", "cancel"])
    func heldSecondAccessKeepsRequestFences(_ action: String) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let file = fixture.file(store, position: 256)
            let held = try #require(store.fileCoordinator.tryAcquire(to: file))
            defer { held.release() }
            let task = Task {
                let result = await store.stage(requestID: .init(909), request: fixture.request(),
                    reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                        probe.record(manifest.position)
                        if manifest.position == 512 { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                        return try probe.cpuPlan(manifest, fixture: fixture)
                    }
                probe.didCompleteStage()
                return result
            }
            let settled = await SSDShorterRestoreGate.waitUntil {
                store.fileCoordinator.pendingCount(for: file) == 1 || probe.stageCompleted
            }
            #expect(settled, "stage must either queue the shorter access or return")
            #expect(store.fileCoordinator.pendingCount(for: file) == 1,
                "baseline returns after one capacity failure; the bounded fallback must reach this owned wait")
            switch action {
            case "complete": store.completeStaging(requestID: .init(909))
            case "close": store.close()
            case "epoch": #expect(store.config.epochStore?.rotate() != nil)
            default: task.cancel()
            }
            if !settled { task.cancel(); store.close() }
            held.release()
            let result = await task.value
            #expect(result.disposition == .skippedPolicy)
            #expect(probe.positions == [512] && probe.evaluatedPositions.isEmpty)
            #expect(store.stats().filesRead == 1 && store.stats().corruptDropped == 0)
            #expect(store.lock.withLock { store.stages.isEmpty && store.authenticatedReceipts.isEmpty })
        }
    }
}
