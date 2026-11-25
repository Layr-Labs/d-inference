import Foundation
import Dispatch
import MLX

/// Root owns the loaded stage, admitted input/environment/agreement and group.
/// This owner admits the local stage before a peer readiness exchange, emits the
/// optional ready callback, then starts rank zero's diagnostic clock. Neither a
/// full model nor an external reference is loaded or parsed by this function.
func runQwenLongPrefillRankRequest(loaded: LoadedQwenLayerStage,
    local: QwenRegistered9BLongPrefillReferenceAdmission,
    agreement: QwenLayerStageProfiledPrefillStartAgreement, collective: Collective,
    onReady: () throws -> Void = {}, check: () throws -> Void
) throws -> QwenLongPrefillRankRequestResult {
    var context: QwenLayerStageProfiledPrefillComputeContext?
    var ownedTransport: QwenLayerStageProfiledPrefillTransport?
    var retiredCleanly = false
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            _ = try QwenLayerStageProfiledComputeAdmission(loaded: loaded, local: local, agreement: agreement)
            let transport = try QwenLayerStageProfiledPrefillTransport(collective: collective,
                agreement: agreement, admittedRank: loaded.stageIndex)
            ownedTransport = transport
            let trace = try QwenLongPrefillRankTrace(frameCount: local.request.steps.count)
            let startPacket = try QwenLayerStageProfiledPrefillStartWirePacket(agreement: agreement)
            func control(_ phase: QwenLayerStageProfiledPrefillControlPhase) throws {
                try trace.record("control.\(phase)", context: context, transport: transport, prepared: false)
            }
            try checked()
            try trace.record("readiness.begin", context: nil, transport: transport, prepared: false)
            let readiness = try requireQwenLongPrefillRankReadiness(agreement, collective: collective, check: checked)
            try trace.record("readiness.completed", context: nil, transport: transport, prepared: false)
            try onReady(); try checked()
            let startTime: UInt64?
            if transport.rank == 0 {
                startTime = DispatchTime.now().uptimeNanoseconds
                try transport.sendStart(startPacket, onPhase: control, check: checked)
            } else {
                startTime = nil
                _ = try transport.receiveStart(onPhase: control, check: checked)
            }
            guard transport.startCompleted, !transport.isFailed else {
                throw ProbeError("Long start did not finish before fresh request-state construction")
            }
            let fresh = try QwenLayerStageProfiledPrefillComputeContext(loaded: loaded,
                local: local, agreement: agreement, check: checked)
            context = fresh
            try requireQwenLongPrefillRankIdentity(fresh.identity, agreement: agreement, rank: transport.rank)
            guard fresh.committedTokens == 0, fresh.committedFrames == 0, !fresh.isFailed, !fresh.isClosed else {
                throw ProbeError("Long rank was given reused or retired request state")
            }
            try trace.record("freshContextCreated", context: fresh, transport: transport, prepared: false)
            let frames: [QwenLongPrefillRankFrame], ahead: Int, released: Int
            let selection: QwenLayerStagePrefillTokenReceipt?
            if transport.rank == 0 {
                let sent = try runQwenLongPrefillRankSender(context: fresh, transport: transport, trace: trace, check: checked)
                frames = sent.frames; ahead = sent.preparedAheadFrames
                released = sent.releasedOriginalBoundaryHandles; selection = nil
            } else {
                let received = try runQwenLongPrefillRankReceiver(context: fresh, transport: transport, trace: trace, check: checked)
                frames = received.frames; ahead = 0
                released = received.releasedOriginalBoundaryHandles; selection = received.selection
            }
            guard fresh.isPrefillComplete, !fresh.isFailed, !fresh.isClosed,
                  transport.completedBoundaryCount == 16, !transport.hasPendingConsumption else {
                throw ProbeError("Long token return began before every native commit and consumed acknowledgement")
            }
            let token: QwenLayerStageProfiledPrefillFirstTokenWirePacket
            let stopTime: UInt64?
            if transport.rank == 0 {
                token = try transport.receiveFirstToken(onPhase: control, check: checked)
                stopTime = DispatchTime.now().uptimeNanoseconds
                try trace.record("firstTokenStopRecorded", context: fresh, transport: transport, prepared: false)
                try transport.sendPostStopRelease(onPhase: control, check: checked)
            } else {
                token = try transport.sendFirstToken(onPhase: control, check: checked)
                stopTime = nil
                try transport.receivePostStopRelease(onPhase: control, check: checked)
            }
            guard transport.isComplete, transport.postStopReleaseCompleted, !transport.isFailed else {
                throw ProbeError("Long final diagnostics require completed post-stop release")
            }
            try trace.record("postStopDiagnostics.begin", context: fresh, transport: transport, prepared: false)
            let final = try fresh.captureFinalDigestsAfterPostStop(check: checked)
            guard fresh.finalObservationCompleted, final.identity == fresh.identity,
                  final.agreementFingerprint == agreement.fingerprint,
                  final.completedFrames == 16, final.committedTokens == 8192,
                  (final.finalLogits != nil) == (transport.rank == 1) else {
                throw ProbeError("Long final digest lost its admitted identity, role or frontier")
            }
            try fresh.close()
            guard fresh.isClosed, !fresh.isFailed, !fresh.hasFinalLogits else {
                throw ProbeError("Long rank failed to retire its request cleanly")
            }
            retiredCleanly = true
            try checked()
            guard transport.isComplete, !transport.isFailed else {
                throw ProbeError("Long rank transport lost completion after request retirement")
            }
            try trace.record("requestClosed", context: fresh, transport: transport, prepared: false)
            let timing: QwenLongPrefillRankTiming?
            if let startTime, let stopTime {
                timing = try qwenLongPrefillRankTiming(start: startTime, stop: stopTime,
                    closed: DispatchTime.now().uptimeNanoseconds)
            } else { timing = nil }
            return .init(profile: local.request.request.profile,
                profileFingerprint: local.request.request.profile.fingerprint,
                agreementFingerprint: agreement.fingerprint, identity: fresh.identity, readiness: readiness,
                frames: frames, actions: trace.actions, selectedTokenID: token.tokenID,
                exactTokenPacketJSON: String(decoding: token.encoded(), as: UTF8.self),
                tokenPacketFingerprint: token.fingerprint, tokenPacketWireBytesSHA256: token.wireBytesSHA256,
                localSelection: selection, finalDigest: final,
                completedFrames: fresh.committedFrames, committedTokens: fresh.committedTokens,
                preparedAheadFrames: ahead, releasedOriginalBoundaryHandles: released, timing: timing)
        }
    } catch {
        let primary = error
        ownedTransport?.retire()
        var cleanup: [String] = []
        if let context, !retiredCleanly {
            do { try MLX.withError { error in try context.cancel(); try error.check() } }
            catch { cleanup.append(String(describing: error)) }
            if !context.isClosed || !context.isFailed || context.hasFinalLogits {
                cleanup.append("local long request remained live after cancellation")
            }
        }
        if !cleanup.isEmpty {
            throw ProbeError("Long rank failed (\(primary)); local retirement also failed (\(cleanup.joined(separator: "; ")))")
        }
        throw primary
    }
}
