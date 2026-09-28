import Foundation

/// Admission/order regression checks for later Foundation-only invocation.
enum QwenLayerStageOverlapCheck {
    struct Result: Encodable {
        let flow = QwenLayerStageOverlapFlow.name
        let traces: [QwenLayerStageOverlapTraceCheck.Result]
        let rejectedTransitions: [String]
        let maximumFrameCount: Int
    }

    static func run() throws -> Result {
        let plan = try makePlan(prompt: 65, chunk: 32, output: 4)
        guard plan.frames.map(\.tokenOffset) == [0, 32, 64, 65, 66, 67],
              plan.frames.map(\.tokenCount) == [32, 32, 1, 1, 1, 1],
              plan.frames.map(\.phase) == [.prefill, .prefill, .prefill, .decode, .decode, .decode],
              plan.frames.map(\.finalPromptChunk) == [false, false, true, false, false, false] else {
            throw ProbeError("Overlap changed the agreed 65/32/4 timeline")
        }
        var traces: [QwenLayerStageOverlapTraceCheck.Result] = []
        for buffered in [false, true] {
            let trace = try QwenLayerStageOverlapTraceCheck.run(plan: plan, bufferedConsumedACK: buffered)
            guard trace.frameCount == 6, trace.promptLookaheadCount == 2,
                  trace.maximumProducedMinusCompleted == 2, trace.finalCommittedTokens == 68 else {
                throw ProbeError("Overlap trace changed its expected queue/frontier bound")
            }
            traces.append(trace)
        }
        let maximum = try makePlan(prompt: 128, chunk: 1, output: 4)
        guard maximum.frames.count == 131 else { throw ProbeError("Bounded overlap frame cap changed") }
        traces.append(try QwenLayerStageOverlapTraceCheck.run(plan: maximum, bufferedConsumedACK: false))
        let single = try makePlan(prompt: 1, chunk: 32, output: 1, admission: .prefillOnly)
        let singleTrace = try QwenLayerStageOverlapTraceCheck.run(plan: single, bufferedConsumedACK: true)
        guard singleTrace.promptLookaheadCount == 0, singleTrace.finalCommittedTokens == 1 else {
            throw ProbeError("Single prompt frame failed its mandatory final drain")
        }
        traces.append(singleTrace)
        var rejected = try senderRejections(plan)
        rejected += try receiverRejections(plan)
        do {
            _ = try makePlan(prompt: 65, chunk: 32, output: 4, admission: .prefillOnly)
            throw CheckFailure.acceptedForbiddenDecode
        } catch CheckFailure.acceptedForbiddenDecode { throw ProbeError("Prefill-only plan admitted decode") }
        catch { rejected.append("prefill_only_rejects_decode_timeline") }
        return .init(traces: traces, rejectedTransitions: rejected, maximumFrameCount: maximum.frames.count)
    }

    private enum CheckFailure: Error { case acceptedForbiddenDecode }

    private static func makePlan(prompt: Int, chunk: Int, output: Int,
        admission: QwenLayerStageOverlapDecodeAdmission = .frozenTeacherDiagnostic) throws -> QwenLayerStageOverlapPlan {
        let request = try QwenLayerStageRequestSpec(requestID: UUID(uuidString: "3CCB5605-FCC6-4364-8CAB-C0B2DBC41625")!,
                                                  promptCount: prompt, chunkSize: chunk, outputCount: output)
        return try .init(request: request, decodeAdmission: admission)
    }

    private static func senderRejections(_ plan: QwenLayerStageOverlapPlan) throws -> [String] {
        let first = plan.frames[0], next = plan.frames[1]
        let ticket = try QwenLayerStageOverlapTraceCheck.ticket(plan: plan, frame: first)
        let wrong = try QwenLayerStageOverlapTraceCheck.ticket(plan: plan, frame: first, salt: "wrong")
        var rejected: [String] = []
        let empty = QwenLayerStageOverlapSender(plan: plan)
        rejected.append(try rejectSender("out_of_order_preparation", empty) { try $0.beginPreparation(next) })
        rejected.append(try rejectSender("premature_close", empty) { try $0.close() })
        var preparing = empty; try preparing.beginPreparation(first)
        rejected.append(try rejectSender("concurrent_preparation", preparing) { try $0.beginPreparation(first) })
        rejected.append(try rejectSender("wrong_local_commit", preparing) {
            try $0.preparationCompleted(first, committedTokens: 31)
        })
        let held = try QwenLayerStageOverlapTraceCheck.senderAfterReceived(plan: plan, ticket: ticket, releaseSource: false)
        rejected.append(try rejectSender("prepare_before_source_release", held) { try $0.beginPreparation(next) })
        rejected.append(try rejectSender("duplicate_received_ack", held) { try $0.receivedACKAccepted(ticket) })
        var pending = held; try pending.sentSourceReleased(ticket)
        rejected.append(try rejectSender("wrong_consumed_ticket", pending) { try $0.beginConsumedDrain(wrong) })
        var ahead = pending; try ahead.beginPreparation(next)
        rejected.append(try rejectSender("drain_during_native_preparation", ahead) { try $0.beginConsumedDrain(ticket) })
        try ahead.preparationCompleted(next, committedTokens: 64)
        let nextTicket = try QwenLayerStageOverlapTraceCheck.ticket(plan: plan, frame: next)
        rejected.append(try rejectSender("next_header_before_consumed_ack", ahead) { try $0.beginHeader(nextTicket) })
        rejected.append(try rejectSender("second_prepared_output", ahead) { try $0.beginPreparation(plan.frames[2]) })
        var draining = ahead; try draining.beginConsumedDrain(ticket)
        rejected.append(try rejectSender("wrong_consumed_ack_digest", draining) { try $0.consumedACKAccepted(wrong) })
        let decodePlan = try makePlan(prompt: 1, chunk: 32, output: 4)
        let decodeTicket = try QwenLayerStageOverlapTraceCheck.ticket(plan: decodePlan, frame: decodePlan.frames[0])
        let finalPending = try QwenLayerStageOverlapTraceCheck.senderAfterReceived(
            plan: decodePlan, ticket: decodeTicket, releaseSource: true)
        rejected.append(try rejectSender("teacher_decode_cannot_look_ahead", finalPending) {
            try $0.beginPreparation(decodePlan.frames[1])
        })
        var retired = pending; retired.retire()
        rejected.append(try rejectSender("retired_sender_is_not_reusable", retired) { try $0.beginPreparation(next) })
        return rejected
    }

    private static func receiverRejections(_ plan: QwenLayerStageOverlapPlan) throws -> [String] {
        let ticket = try QwenLayerStageOverlapTraceCheck.ticket(plan: plan, frame: plan.frames[0])
        let wrong = try QwenLayerStageOverlapTraceCheck.ticket(plan: plan, frame: plan.frames[1])
        var receiver = QwenLayerStageOverlapReceiver(plan: plan)
        var rejected = [try rejectReceiver("receiver_premature_close", receiver) { try $0.close() }]
        try receiver.beginHeaderReceive()
        rejected.append(try rejectReceiver("out_of_order_receiver_header", receiver) { try $0.headerValidated(wrong) })
        receiver = try QwenLayerStageOverlapTraceCheck.receiverAwaitingPayload(plan: plan, ticket: ticket)
        rejected.append(try rejectReceiver("received_ack_before_payload_validation", receiver) { try $0.beginReceivedACK(ticket) })
        try receiver.payloadReceivedAndValidated(ticket); try receiver.beginReceivedACK(ticket)
        rejected.append(try rejectReceiver("compute_before_received_ack_completed", receiver) { try $0.beginConsumption(ticket) })
        try receiver.receivedACKSendCompleted(ticket); try receiver.beginConsumption(ticket)
        rejected.append(try rejectReceiver("consumed_ack_before_commit_and_capture", receiver) { try $0.beginConsumedACK(ticket) })
        try receiver.consumptionAndCaptureCompleted(ticket, committedTokens: 32)
        rejected.append(try rejectReceiver("consumed_ack_before_boundary_release", receiver) { try $0.beginConsumedACK(ticket) })
        try receiver.consumedBoundaryReleased(ticket); try receiver.beginConsumedACK(ticket)
        rejected.append(try rejectReceiver("next_header_while_consumed_send_pending", receiver) { try $0.beginHeaderReceive() })
        try receiver.consumedACKSendCompleted(ticket)
        rejected.append(try rejectReceiver("duplicate_consumed_send_completion", receiver) { try $0.consumedACKSendCompleted(ticket) })
        receiver.retire()
        rejected.append(try rejectReceiver("retired_receiver_is_not_reusable", receiver) { try $0.beginHeaderReceive() })
        return rejected
    }

    private static func rejectSender(_ name: String, _ original: QwenLayerStageOverlapSender,
        attempt: (inout QwenLayerStageOverlapSender) throws -> Void) throws -> String {
        var value = original, rejected = false
        do { try attempt(&value) } catch { rejected = true }
        guard rejected, value.isFailed else { throw ProbeError("Sender accepted or failed to retire: \(name)") }
        return name
    }

    private static func rejectReceiver(_ name: String, _ original: QwenLayerStageOverlapReceiver,
        attempt: (inout QwenLayerStageOverlapReceiver) throws -> Void) throws -> String {
        var value = original, rejected = false
        do { try attempt(&value) } catch { rejected = true }
        guard rejected, value.isFailed else { throw ProbeError("Receiver accepted or failed to retire: \(name)") }
        return name
    }
}
