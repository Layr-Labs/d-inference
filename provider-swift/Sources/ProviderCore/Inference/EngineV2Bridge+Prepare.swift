// Copyright © 2026 Eigen Labs.
//
// Real non-emitting admission for prepared leases. CBv2 has no resumable
// prefill boundary, so prepare reserves exact admission resources without
// submitting, staging a prefix-cache hit, or emitting output.

import Foundation
import MLXLMCommon

public enum PreparedInferenceAdmissionError: Error, Equatable, Sendable {
    case identityConflict
    case modelMismatch(expected: String, actual: String)
    case promptTokenCountMismatch(expected: Int, actual: Int)
    case maxOutputTokenCountMismatch(expected: Int, actual: Int)
    case duplicateLease
    case duplicateRequestID
    case concurrencyExhausted(limit: Int)
    case kvSizingUnavailable
    case kvArithmeticOverflow
    case kvCapacityExhausted(needed: UInt64, available: UInt64)
    case mediaAdmissionUnavailable(bytes: UInt64)
    case unifiedMemoryCapacityExhausted(needed: UInt64)
    case leaseExpired
    case unknownLease
    case engineTerminalWedge
}

extension EngineV2Bridge: PreparedInferenceExecutor {
    public func prepareInference(
        _ inference: PreparedInference,
        expiresAt: Date
    ) async throws -> PreparedInferenceAdmission {
        let identity = inference.identity
        let leaseID = identity.leaseID
        guard !preparedTerminalWedge else {
            throw PreparedInferenceAdmissionError.engineTerminalWedge
        }
        guard inference.modelID == modelId else {
            throw PreparedInferenceAdmissionError.modelMismatch(
                expected: modelId, actual: inference.modelID)
        }
        guard inference.promptTokens.count == inference.facts.promptTokens else {
            throw PreparedInferenceAdmissionError.promptTokenCountMismatch(
                expected: inference.facts.promptTokens,
                actual: inference.promptTokens.count)
        }

        var request = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(0),
            promptTokens: inference.promptTokens,
            request: inference.request,
            defaultMaxTokens: defaultMaxTokens,
            stopTokenIds: stopTokenIds,
            cacheScope: inference.cacheScope,
            multimodal: inference.multimodal)
        guard request.maxTokens == inference.facts.maxOutputTokens else {
            throw PreparedInferenceAdmissionError.maxOutputTokenCountMismatch(
                expected: inference.facts.maxOutputTokens,
                actual: request.maxTokens)
        }
        guard expiresAt > Date() else {
            throw PreparedInferenceAdmissionError.leaseExpired
        }
        try validateUnusedPreparedIdentity(identity)
        guard !requestIDIsClaimed(inference.requestID) else {
            throw PreparedInferenceAdmissionError.duplicateRequestID
        }
        guard active.count + preparedRequests.count < maxConcurrentRequests else {
            throw PreparedInferenceAdmissionError.concurrencyExhausted(
                limit: maxConcurrentRequests)
        }

        let reservedKVBytes = try preparedKVBytes(
            promptTokens: inference.promptTokens.count,
            maxOutputTokens: request.maxTokens)
        try checkPreparedLocalCapacity(addingKVBytes: reservedKVBytes)

        let reservedMediaBytes = inference.facts.mediaBytes
        if reservedMediaBytes > 0, kvBudget == nil {
            throw PreparedInferenceAdmissionError.mediaAdmissionUnavailable(
                bytes: reservedMediaBytes)
        }
        let (totalReservedBytes, overflow) =
            reservedKVBytes.addingReportingOverflow(reservedMediaBytes)
        guard !overflow else {
            throw PreparedInferenceAdmissionError.kvArithmeticOverflow
        }

        var holdsSharedReservation = false
        if totalReservedBytes > 0, let kvBudget {
            holdsSharedReservation = await kvBudget.reserveBytes(
                requestID: inference.requestID,
                bytes: totalReservedBytes)
            guard holdsSharedReservation else {
                throw PreparedInferenceAdmissionError.unifiedMemoryCapacityExhausted(
                    needed: totalReservedBytes)
            }

            // The actor hop permits another admission to interleave. Recheck
            // every local promise before publishing this reservation.
            do {
                guard !preparedTerminalWedge else {
                    throw PreparedInferenceAdmissionError.engineTerminalWedge
                }
                guard expiresAt > Date() else {
                    throw PreparedInferenceAdmissionError.leaseExpired
                }
                try validateUnusedPreparedIdentity(identity)
                guard !requestIDIsClaimed(inference.requestID) else {
                    throw PreparedInferenceAdmissionError.duplicateRequestID
                }
                guard active.count + preparedRequests.count < maxConcurrentRequests else {
                    throw PreparedInferenceAdmissionError.concurrencyExhausted(
                        limit: maxConcurrentRequests)
                }
                try checkPreparedLocalCapacity(addingKVBytes: reservedKVBytes)
            } catch {
                await kvBudget.release(requestID: inference.requestID)
                throw error
            }
        }

        request.id = CBv2RequestID(0)
        preparedRequests[leaseID] = PreparedRequestState(
            inference: inference,
            request: request,
            expiresAt: expiresAt,
            reservedKVBytes: reservedKVBytes,
            reservedMediaBytes: reservedMediaBytes,
            holdsSharedReservation: holdsSharedReservation)

        let capacity = engine.capacity()
        return PreparedInferenceAdmission(
            promptTokens: inference.promptTokens.count,
            maxOutputTokens: request.maxTokens,
            engineQueueDepth: max(0, capacity.waitingRequests),
            reservedKVBytes: reservedKVBytes,
            reservedMediaBytes: reservedMediaBytes,
            prefillCanBegin: false,
            estimatedPrefillMilliseconds: nil)
    }

    public func startPreparedInference(
        identity: AttemptIdentity
    ) async throws -> PreparedInferenceExecution {
        let leaseID = identity.leaseID
        guard !preparedTerminalWedge else {
            throw PreparedInferenceAdmissionError.engineTerminalWedge
        }
        guard var state = preparedRequests[leaseID] else {
            if let started = startedPreparedRequests[leaseID] {
                guard started.identity == identity else {
                    throw PreparedInferenceAdmissionError.identityConflict
                }
                throw PreparedInferenceAdmissionError.duplicateLease
            }
            throw PreparedInferenceAdmissionError.unknownLease
        }
        guard state.inference.identity == identity else {
            throw PreparedInferenceAdmissionError.identityConflict
        }
        guard state.expiresAt > Date() else {
            preparedRequests.removeValue(forKey: leaseID)
            applyDeferredKVBytesCapacityIfPossible()
            if state.holdsSharedReservation {
                await kvBudget?.release(requestID: state.inference.requestID)
            }
            await state.inference.resourceRelease.fire()
            throw PreparedInferenceAdmissionError.leaseExpired
        }

        state.phase = .starting
        preparedRequests[leaseID] = state

        // Prefix staging is start-only. It is not resumable prefill.
        var ssdStaged = false
        if let ssd = ssdPrefixCache, state.inference.multimodal == nil {
            ssdStaged = await ssd.stage(
                requestID: state.inference.requestID,
                promptTokens: state.inference.promptTokens,
                cacheScope: state.inference.cacheScope)
        }

        guard var current = preparedRequests[leaseID] else {
            if ssdStaged {
                ssdPrefixCache?.completeStaging(requestID: state.inference.requestID)
            }
            throw PreparedInferenceAdmissionError.unknownLease
        }
        guard current.inference.identity == identity else {
            if ssdStaged {
                ssdPrefixCache?.completeStaging(requestID: state.inference.requestID)
            }
            throw PreparedInferenceAdmissionError.identityConflict
        }
        current.request.id = mintEngineRequestId(
            seed: current.request.sampling.seed,
            promptTokens: current.inference.promptTokens)

        let events: AsyncStream<CBv2Event>
        do {
            // Any re-slice requested after prepare remains deferred until
            // this submit has been judged against the same ceiling.
            events = try engine.submit(current.request)
        } catch {
            preparedRequests.removeValue(forKey: leaseID)
            applyDeferredKVBytesCapacityIfPossible()
            if current.holdsSharedReservation {
                await kvBudget?.release(requestID: current.inference.requestID)
            }
            if ssdStaged {
                ssdPrefixCache?.completeStaging(requestID: current.inference.requestID)
            }
            await current.inference.resourceRelease.fire()
            throw error
        }

        let requestID = current.inference.requestID
        let completion = PreparedInferenceCompletion()
        let usageLedger = PreparedInferenceUsageLedger(
            promptTokens: UInt64(clamping: current.inference.facts.promptTokens)
        )
        active[requestID] = ActiveRequestState(
            promptTokens: current.inference.promptTokens.count,
            maxTokens: current.request.maxTokens,
            submittedAt: .now)
        idMap[requestID] = current.request.id
        startedPreparedRequests[leaseID] = StartedPreparedRequestState(
            identity: identity,
            requestID: requestID,
            engineID: current.request.id,
            holdsSharedReservation: current.holdsSharedReservation,
            resourceRelease: current.inference.resourceRelease,
            completion: completion)
        preparedRequests.removeValue(forKey: leaseID)
        applyDeferredKVBytesCapacityIfPossible()
        wedgeMonitor.recordAdmit(now: .now)

        if current.inference.multimodal != nil {
            emitVisionSubmitTelemetry(
                requestId: requestID,
                mediaKind: current.inference.mediaKind)
        }

        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
        runPump(
            id: requestID,
            events: events,
            continuation: continuation,
            holdsSharedReservation: current.holdsSharedReservation,
            logprobsChannel: current.inference.logprobsChannel,
            usageSignal: current.inference.usageSignal,
            preparedResourceRelease: current.inference.resourceRelease,
            preparedCompletion: completion,
            preparedUsageLedger: usageLedger)

        let bridge = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await bridge.cancel(requestId: requestID) }
            }
        }

        if current.cancelOnStart {
            engine.cancel(current.request.id)
        }
        return PreparedInferenceExecution(
            events: stream,
            completion: completion,
            usageLedger: usageLedger
        )
    }

    public func abortPreparedInference(identity: AttemptIdentity) async {
        await stopPreparedInference(identity: identity)
    }

    public func cancelPreparedInference(identity: AttemptIdentity) async {
        await stopPreparedInference(identity: identity)
    }

    private func stopPreparedInference(identity: AttemptIdentity) async {
        let leaseID = identity.leaseID
        if var prepared = preparedRequests[leaseID] {
            guard prepared.inference.identity == identity else { return }
            if prepared.phase == .starting {
                prepared.cancelOnStart = true
                preparedRequests[leaseID] = prepared
                return
            }
            preparedRequests.removeValue(forKey: leaseID)
            applyDeferredKVBytesCapacityIfPossible()
            if prepared.holdsSharedReservation {
                await kvBudget?.release(requestID: prepared.inference.requestID)
            }
            await prepared.inference.resourceRelease.fire()
            return
        }
        guard let started = startedPreparedRequests[leaseID],
            started.identity == identity
        else { return }
        engine.cancel(started.engineID)
    }

    public func forceReleasePreparedInference(identity: AttemptIdentity) async {
        let leaseID = identity.leaseID
        if let prepared = preparedRequests[leaseID] {
            guard prepared.inference.identity == identity else { return }
            preparedTerminalWedge = true
            preparedRequests.removeValue(forKey: leaseID)
            applyDeferredKVBytesCapacityIfPossible()
            if prepared.holdsSharedReservation {
                await kvBudget?.release(requestID: prepared.inference.requestID)
            }
            await prepared.inference.resourceRelease.fire()
            return
        }
        guard let started = startedPreparedRequests[leaseID],
            started.identity == identity
        else { return }

        preparedTerminalWedge = true
        startedPreparedRequests.removeValue(forKey: leaseID)
        engine.cancel(started.engineID)
        active.removeValue(forKey: started.requestID)
        idMap.removeValue(forKey: started.requestID)
        pumpTasks.removeValue(forKey: started.requestID)?.cancel()
        ssdPrefixCache?.completeStaging(requestID: started.requestID)
        if started.holdsSharedReservation {
            await kvBudget?.release(requestID: started.requestID)
        }
        await started.resourceRelease.fire()
        await started.completion.finish()
    }

    private func validateUnusedPreparedIdentity(_ identity: AttemptIdentity) throws {
        if let prepared = preparedRequests[identity.leaseID] {
            guard prepared.inference.identity == identity else {
                throw PreparedInferenceAdmissionError.identityConflict
            }
            throw PreparedInferenceAdmissionError.duplicateLease
        }
        if let started = startedPreparedRequests[identity.leaseID] {
            guard started.identity == identity else {
                throw PreparedInferenceAdmissionError.identityConflict
            }
            throw PreparedInferenceAdmissionError.duplicateLease
        }
    }

    func preparedKVBytes(
        promptTokens: Int,
        maxOutputTokens: Int
    ) throws -> UInt64 {
        guard maxOutputTokens > 0 else { return 0 }
        guard preparedAdmission.isSizingAvailable else {
            throw PreparedInferenceAdmissionError.kvSizingUnavailable
        }
        let (tokenCount, overflow) =
            promptTokens.addingReportingOverflow(maxOutputTokens)
        guard !overflow, tokenCount >= 0,
            let bytes = preparedAdmission.estimatedBytes(forTokens: tokenCount)
        else {
            throw PreparedInferenceAdmissionError.kvArithmeticOverflow
        }
        return bytes
    }

    func checkPreparedLocalCapacity(addingKVBytes needed: UInt64) throws {
        guard needed > 0 else { return }
        let snapshot = engine.capacity()
        let usableCapacity = UInt64(
            max(
                0,
                preparedAdmission.admissibleBytesCapacity(
                    totalCapacity: snapshot.kvBytesCapacity)))

        var activePotential: UInt64 = 0
        for state in active.values {
            let (tokens, overflow) =
                state.promptTokens.addingReportingOverflow(max(0, state.maxTokens))
            guard !overflow,
                let bytes = preparedAdmission.estimatedBytes(forTokens: tokens)
            else {
                throw PreparedInferenceAdmissionError.kvArithmeticOverflow
            }
            let (sum, sumOverflow) = activePotential.addingReportingOverflow(bytes)
            guard !sumOverflow else {
                throw PreparedInferenceAdmissionError.kvArithmeticOverflow
            }
            activePotential = sum
        }

        var preparedPotential: UInt64 = 0
        for state in preparedRequests.values {
            let (sum, overflow) =
                preparedPotential.addingReportingOverflow(state.reservedKVBytes)
            guard !overflow else {
                throw PreparedInferenceAdmissionError.kvArithmeticOverflow
            }
            preparedPotential = sum
        }

        let engineMaterialized = UInt64(max(0, snapshot.kvBytesInUse))
        var committed = max(engineMaterialized, activePotential)
        let (withPrepared, overflow) =
            committed.addingReportingOverflow(preparedPotential)
        committed = overflow ? UInt64.max : withPrepared
        let available = usableCapacity > committed ? usableCapacity - committed : 0
        guard needed <= available else {
            throw PreparedInferenceAdmissionError.kvCapacityExhausted(
                needed: needed, available: available)
        }
    }
}
