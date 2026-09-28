import Foundation
import Dispatch
import MLX

/// Models and token IDs are ready before entry. The owner keeps all native work
/// on this thread; any error retires this transport/context and the parent must
/// fence the entire process pair. No request state exists before the start IO.
func runQwenLayerStagePrefillRankRequest(loaded: LoadedQwenLayerStage,
    plan: QwenLayerStagePlan, agreement: QwenLayerStagePrefillStartAgreement,
    transport: QwenLayerStagePrefillTransport, check: () throws -> Void
) throws -> QwenLayerStagePrefillRankRequestResult {
    var context: QwenLayerStagePrefillComputeContext?
    let trace = try QwenLayerStagePrefillRankTrace(frameCount: agreement.request.steps.count)
    let startPacket = try QwenLayerStagePrefillStartWirePacket(agreement: agreement)
    do {
        guard loaded.stageIndex == transport.rank, transport.agreement.fingerprint == agreement.fingerprint,
              !transport.isFailed, !transport.startCompleted else {
            throw ProbeError("Prefill request needs a fresh transport and the admitted loaded rank")
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            func control(_ phase: QwenLayerStagePrefillControlPhase) throws {
                try trace.record("control.\(phase)", context: context, transport: transport, prepared: false)
            }
            try checked()
            let startTime: UInt64?
            if transport.rank == 0 {
                startTime = DispatchTime.now().uptimeNanoseconds
                try transport.sendStart(startPacket, onPhase: control, check: checked)
            } else {
                startTime = nil
                _ = try transport.receiveStart(onPhase: control, check: checked)
            }
            guard transport.startCompleted else { throw ProbeError("Prefill start did not finish before fresh request-state creation") }
            let fresh = try QwenLayerStagePrefillComputeContext(loaded: loaded, plan: plan, request: agreement.request)
            context = fresh
            try requirePrefillRankIdentity(fresh.identity, agreement: agreement, rank: transport.rank)
            guard fresh.committedTokens == 0, fresh.committedFrames == 0 else {
                throw ProbeError("Prefill measurement was given reused request state")
            }
            try trace.record("freshContextCreated", context: fresh, transport: transport, prepared: false)
            let frames: [QwenLayerStagePrefillRankFrame]
            let ahead: Int, released: Int
            let selection: QwenLayerStagePrefillTokenReceipt?
            if transport.rank == 0 {
                let sent = try runQwenLayerStagePrefillRankSender(context: fresh,
                    transport: transport, trace: trace, check: checked)
                frames = sent.frames; ahead = sent.preparedAheadFrames
                released = sent.releasedOriginalBoundaryHandles; selection = nil
            } else {
                let received = try runQwenLayerStagePrefillRankReceiver(context: fresh,
                    transport: transport, trace: trace, check: checked)
                frames = received.frames; ahead = 0
                released = received.releasedOriginalBoundaryHandles; selection = received.selection
            }
            guard fresh.isPrefillComplete, !fresh.isFailed, !fresh.isClosed,
                  transport.completedBoundaryCount == agreement.request.steps.count,
                  !transport.hasPendingConsumption else {
                throw ProbeError("Prefill token return began before final native commit and consumed acknowledgement")
            }
            let token: QwenLayerStagePrefillFirstTokenWirePacket
            let stopTime: UInt64?
            if transport.rank == 0 {
                token = try transport.receiveFirstToken(onPhase: control, check: checked)
                // Receive has validated the actual selected token and final
                // consumed gate. Read the clock before any post-stop event.
                stopTime = DispatchTime.now().uptimeNanoseconds
                try trace.record("firstTokenStopRecorded", context: fresh, transport: transport, prepared: false)
                try transport.sendPostStopRelease(onPhase: control, check: checked)
            } else {
                token = try transport.sendFirstToken(onPhase: control, check: checked)
                stopTime = nil
                try transport.receivePostStopRelease(onPhase: control, check: checked)
            }
            guard transport.isComplete, transport.postStopReleaseCompleted else {
                throw ProbeError("Prefill diagnostics require the completed post-stop release protocol")
            }
            try trace.record("postStopDiagnostics.begin", context: fresh, transport: transport, prepared: false)
            let snapshot = try fresh.captureFinalStateForDiagnostics(check: checked)
            let state = try QwenLayerStageRankStateCapture(snapshot: snapshot,
                stage: plan.stages[transport.rank], committedTokens: fresh.committedTokens)
            let logits = try transport.rank == 1
                ? fresh.captureFinalLogitsForDiagnostics(check: checked).metadata : nil
            try fresh.close(); try checked()
            guard fresh.isClosed, !fresh.isFailed, transport.isComplete, !transport.isFailed else {
                throw ProbeError("Prefill rank lost clean request retirement after its first-token timestamp")
            }
            try trace.record("requestClosed", context: fresh, transport: transport, prepared: false)
            let timing: QwenLayerStagePrefillRankTiming?
            if let startTime, let stopTime {
                let closedTime = DispatchTime.now().uptimeNanoseconds
                guard stopTime > startTime, closedTime >= stopTime else { throw ProbeError("Prefill clock did not advance monotonically") }
                let elapsed = stopTime - startTime
                timing = .init(startUptimeNanoseconds: startTime, stopUptimeNanoseconds: stopTime,
                    elapsedNanoseconds: elapsed,
                    promptTokensPerFirstTokenSecond: Double(agreement.request.request.promptCount) * 1e9 / Double(elapsed),
                    postStopThroughRequestCloseNanoseconds: closedTime - stopTime)
            } else { timing = nil }
            return .init(agreementFingerprint: agreement.fingerprint, identity: fresh.identity,
                frames: frames, actions: trace.actions, selectedTokenID: token.tokenID,
                exactTokenPacketJSON: String(decoding: token.encoded(), as: UTF8.self), tokenPacketSHA256: token.fingerprint,
                localSelection: selection, finalLogits: logits, finalStateEntries: state.entries,
                finalStateLogicalBytes: state.logicalBytes, finalStateSHA256: state.fingerprint,
                completedFrames: fresh.committedFrames, committedTokens: fresh.committedTokens,
                preparedAheadFrames: ahead, releasedOriginalBoundaryHandles: released,
                finalLogitCaptures: transport.rank == 1 ? 1 : 0,
                localTokenSelections: transport.rank == 1 ? 1 : 0, timing: timing)
        }
    } catch {
        let primary = error
        transport.retire()
        if let context {
            do { try context.cancel() }
            catch { throw ProbeError("Prefill rank failed (\(primary)); local request retirement also failed (\(error))") }
        }
        throw primary
    }
}

private func requirePrefillRankIdentity(_ identity: QwenLayerStageSessionIdentity,
    agreement: QwenLayerStagePrefillStartAgreement, rank: Int) throws {
    let d = agreement.descriptor
    let expected = QwenLayerStageSessionIdentity(stageIndex: rank, requestFingerprint: d.requestFingerprint,
        artifactAggregateSHA256: d.artifactAggregateSHA256, storageCommitmentSHA256: d.storageCommitmentSHA256,
        bf16ConversionEnabled: d.bf16ConversionEnabled, sourceConfigurationSHA256: d.sourceConfigurationSHA256,
        constructionConfigurationSHA256: rank == 0 ? d.producerConstructionConfigurationSHA256 : d.consumerConstructionConfigurationSHA256,
        planFingerprint: d.planFingerprint, stageFingerprint: rank == 0 ? d.producerStageFingerprint : d.consumerStageFingerprint,
        activationDType: d.nativeDType)
    guard identity == expected else { throw ProbeError("Fresh prefill context differs from the pre-clock admitted source and rank identity") }
}
