import Foundation
import CryptoKit

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func qwenStageWireIsSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
}

import Foundation

/// Same immutable request object is supplied to both stages. No teacher-token
/// policy, sampling, request coalescing or changed microchunk schedule is hidden here.
struct QwenLayerStageRequestSpec: Codable, Equatable {
    let requestID: UUID
    let promptCount: Int
    let chunkSize: Int
    let outputCount: Int

    init(requestID: UUID, promptCount: Int, chunkSize: Int, outputCount: Int) throws {
        guard (1...128).contains(promptCount), (1...32).contains(chunkSize),
            (1...4).contains(outputCount) else {
            throw ProbeError("Initial layer stages require prompt<=128, chunk<=32, output<=4 and batch one")
        }
        self.requestID = requestID; self.promptCount = promptCount
        self.chunkSize = chunkSize; self.outputCount = outputCount
    }

    private enum CodingKeys: String, CodingKey { case requestID, promptCount, chunkSize, outputCount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: values.decode(UUID.self, forKey: .requestID),
            promptCount: values.decode(Int.self, forKey: .promptCount),
            chunkSize: values.decode(Int.self, forKey: .chunkSize),
            outputCount: values.decode(Int.self, forKey: .outputCount))
    }

    var fingerprint: String {
        // UUID and integers have a stable explicit representation independent of JSONEncoder options.
        sha256(Data("qwen-stage-request-v1|\(requestID.uuidString.lowercased())|\(promptCount)|\(chunkSize)|\(outputCount)".utf8))
    }
}

struct QwenLayerStageFrame: Codable, Equatable {
    enum Phase: String, Codable { case prefill, decode }
    let sequence: Int
    let phase: Phase
    let tokenOffset: Int
    let tokenCount: Int
    let finalPromptChunk: Bool
}

/// Pure admission and frontier bookkeeping; advance only after all native
/// outputs/state roots have completed and the recurrent generation committed.
struct QwenLayerStageSchedule {
    let request: QwenLayerStageRequestSpec
    private(set) var committedTokens = 0
    private(set) var committedPromptTokens = 0
    private(set) var decodeForwardCount = 0
    private(set) var nextSequence = 0

    init(request: QwenLayerStageRequestSpec) { self.request = request }

    var complete: Bool {
        committedPromptTokens == request.promptCount && decodeForwardCount == request.outputCount - 1
    }

    func admitPrefill(count: Int, offset: Int, final: Bool) throws -> QwenLayerStageFrame {
        guard committedPromptTokens < request.promptCount, offset == committedTokens,
            count == min(request.chunkSize, request.promptCount - committedPromptTokens),
            final == (committedPromptTokens + count == request.promptCount) else {
            throw ProbeError("Layer-stage prefill differs from the agreed microchunk schedule or token frontier")
        }
        return .init(sequence: nextSequence, phase: .prefill, tokenOffset: offset,
            tokenCount: count, finalPromptChunk: final)
    }

    func admitDecode(offset: Int) throws -> QwenLayerStageFrame {
        guard committedPromptTokens == request.promptCount, offset == committedTokens,
            decodeForwardCount < request.outputCount - 1 else {
            throw ProbeError("Layer-stage decode is outside the agreed token frontier")
        }
        return .init(sequence: nextSequence, phase: .decode, tokenOffset: offset,
            tokenCount: 1, finalPromptChunk: false)
    }

    mutating func commit(_ frame: QwenLayerStageFrame) throws {
        let expected = try frame.phase == .prefill
            ? admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset, final: frame.finalPromptChunk)
            : admitDecode(offset: frame.tokenOffset)
        guard frame == expected else { throw ProbeError("Layer-stage committed frame changed after admission") }
        committedTokens += frame.tokenCount; nextSequence += 1
        if frame.phase == .prefill { committedPromptTokens += frame.tokenCount }
        else { decodeForwardCount += 1 }
    }
}

import Foundation

/// Flow identity is explicit and independent of model/artifact identity. Native
/// integration must validate a closed v2 envelope before ready ACK or payload.
enum QwenLayerStageOverlapFlow {
    static let envelopeVersion = 2
    static let name = "prompt_lookahead_one_v1"
    static let acknowledgementDomain = "qwen-stage-ack-v2"
    static let maximumHeaderBytes = 16 * 1024
    static let maximumFrames = 132
}

/// No generated-token case exists. A future production decode adapter needs a
/// verified rank-one token receipt; consumed ACK alone does not supply a token.
enum QwenLayerStageOverlapDecodeAdmission: String {
    case prefillOnly = "prefill_only"
    case frozenTeacherDiagnostic = "frozen_teacher_diagnostic"
}

/// Reuses the existing exact microchunk admission; contains no native objects,
/// token substitutions, wire parser, clock, model or transport implementation.
struct QwenLayerStageOverlapPlan {
    let request: QwenLayerStageRequestSpec
    let decodeAdmission: QwenLayerStageOverlapDecodeAdmission
    let frames: [QwenLayerStageFrame]

    init(request: QwenLayerStageRequestSpec,
         decodeAdmission: QwenLayerStageOverlapDecodeAdmission) throws {
        guard decodeAdmission != .prefillOnly || request.outputCount == 1 else {
            throw ProbeError("Prefill-only overlap cannot admit decode frames")
        }
        var schedule = QwenLayerStageSchedule(request: request)
        var frames: [QwenLayerStageFrame] = []
        while !schedule.complete {
            let frame: QwenLayerStageFrame
            if schedule.committedPromptTokens < request.promptCount {
                let count = min(request.chunkSize, request.promptCount - schedule.committedPromptTokens)
                frame = try schedule.admitPrefill(count: count, offset: schedule.committedTokens,
                    final: schedule.committedPromptTokens + count == request.promptCount)
            } else {
                frame = try schedule.admitDecode(offset: schedule.committedTokens)
            }
            try schedule.commit(frame)
            frames.append(frame)
            guard frames.count <= QwenLayerStageOverlapFlow.maximumFrames else {
                throw ProbeError("Overlap timeline exceeds its bounded frame count")
            }
        }
        self.request = request; self.decodeAdmission = decodeAdmission; self.frames = frames
    }

    var requestFingerprint: String { request.fingerprint }
    var finalCommittedTokens: Int { request.promptCount + request.outputCount - 1 }

    func matches(_ ticket: QwenLayerStageOverlapTicket, at sequence: Int) -> Bool {
        frames.indices.contains(sequence) && ticket.flow == QwenLayerStageOverlapFlow.name
            && ticket.requestFingerprint == requestFingerprint && ticket.frame == frames[sequence]
    }

    func committedTokens(after frameCount: Int) -> Int {
        precondition((0...frames.count).contains(frameCount))
        guard frameCount > 0 else { return 0 }
        let frame = frames[frameCount - 1]
        return frame.tokenOffset + frame.tokenCount
    }

    func allowsPreparation(at sequence: Int, withPendingConsumedACK: Bool) -> Bool {
        guard frames.indices.contains(sequence) else { return false }
        let frame = frames[sequence]
        if frame.phase == .prefill { return true }
        return !withPendingConsumedACK && decodeAdmission == .frozenTeacherDiagnostic
    }
}

/// CPU-only identity of one actually encoded v2 envelope. Construct only after
/// its header is validated against local expected source/frame/token geometry.
/// The transport owns bounded raw envelope bytes separately for ACK validation.
struct QwenLayerStageOverlapTicket: Equatable {
    let flow: String
    let requestFingerprint: String
    let frame: QwenLayerStageFrame
    let headerSHA256: String

    init(flow: String, requestFingerprint: String, frame: QwenLayerStageFrame,
         headerSHA256: String) throws {
        guard flow == QwenLayerStageOverlapFlow.name,
              qwenStageWireIsSHA256(requestFingerprint), qwenStageWireIsSHA256(headerSHA256) else {
            throw ProbeError("Overlap ticket requires the admitted flow and exact envelope/request hashes")
        }
        self.flow = flow; self.requestFingerprint = requestFingerprint
        self.frame = frame; self.headerSHA256 = headerSHA256
    }
}

import Foundation

/// Pure rank-zero sequencing. Each begin/completed pair brackets a synchronous
/// native or wire operation; no other operation may run inside that interval.
/// Event names assert completed work; they do not execute or prove that work.
struct QwenLayerStageOverlapSender {
    enum Activity: String {
        case idle, preparing, sendingHeader, awaitingReady, readyForPayload
        case sendingPayload, awaitingReceived, drainingConsumed, closed, failed
    }

    enum NextAction: Equatable {
        case prepare(QwenLayerStageFrame), sendPrepared(QwenLayerStageFrame)
        case releaseSentSource(QwenLayerStageOverlapTicket), drainConsumed(QwenLayerStageOverlapTicket)
        case close, inProgress, unavailable
    }

    let plan: QwenLayerStageOverlapPlan
    private(set) var activity: Activity = .idle
    private(set) var producedFrames = 0
    private(set) var receivedFrames = 0
    private(set) var completedFrames = 0
    private(set) var preparedFrame: QwenLayerStageFrame?
    private(set) var pendingConsumed: QwenLayerStageOverlapTicket?
    private(set) var sourceReleaseRequired = false
    private var preparingFrame: QwenLayerStageFrame?
    private var transmitting: QwenLayerStageOverlapTicket?

    init(plan: QwenLayerStageOverlapPlan) { self.plan = plan }

    var isFailed: Bool { activity == .failed }
    var isClosed: Bool { activity == .closed }
    var committedTokens: Int { plan.committedTokens(after: producedFrames) }
    var peerAcknowledgedTokens: Int { plan.committedTokens(after: completedFrames) }

    var canPrepareNext: Bool {
        activity == .idle && preparedFrame == nil && !sourceReleaseRequired
            && plan.allowsPreparation(at: producedFrames, withPendingConsumedACK: pendingConsumed != nil)
    }

    var nextAction: NextAction {
        guard activity == .idle else { return isClosed || isFailed ? .unavailable : .inProgress }
        if let ticket = pendingConsumed {
            if sourceReleaseRequired { return .releaseSentSource(ticket) }
            if canPrepareNext { return .prepare(plan.frames[producedFrames]) }
            return .drainConsumed(ticket)
        }
        if let frame = preparedFrame { return .sendPrepared(frame) }
        if canPrepareNext { return .prepare(plan.frames[producedFrames]) }
        return completedFrames == plan.frames.count ? .close : .unavailable
    }

    mutating func beginPreparation(_ frame: QwenLayerStageFrame) throws {
        try require(canPrepareNext && plan.frames[producedFrames] == frame,
                    "Preparation violates prompt-only lookahead or the single prepared slot")
        preparingFrame = frame; activity = .preparing
    }

    /// Call only after output + all native state roots commit, CPU capture and
    /// the throwing observer succeed. A failed callback retires the cohort.
    mutating func preparationCompleted(_ frame: QwenLayerStageFrame, committedTokens: Int) throws {
        try require(activity == .preparing && preparingFrame == frame
            && committedTokens == frame.tokenOffset + frame.tokenCount,
            "Prepared output does not match its evaluated local frontier")
        preparedFrame = frame; preparingFrame = nil; producedFrames += 1; activity = .idle
    }

    mutating func beginHeader(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .idle && pendingConsumed == nil && !sourceReleaseRequired
            && preparedFrame == ticket.frame && plan.matches(ticket, at: completedFrames),
            "Next header requires the previous consumed ACK and exactly its prepared output")
        transmitting = ticket; activity = .sendingHeader
    }

    mutating func headerSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingHeader && transmitting == ticket,
                    "Header send completion is out of order")
        activity = .awaitingReady
    }

    mutating func readyACKAccepted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .awaitingReady && transmitting == ticket,
                    "Ready ACK differs from the active envelope")
        activity = .readyForPayload
    }

    mutating func beginPayloadSend(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForPayload && transmitting == ticket,
                    "Payload send lacks its validated ready ACK")
        activity = .sendingPayload
    }

    mutating func payloadSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingPayload && transmitting == ticket,
                    "Payload send completion is out of order")
        activity = .awaitingReceived
    }

    mutating func receivedACKAccepted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .awaitingReceived && transmitting == ticket && pendingConsumed == nil,
                    "Received ACK differs from the single transmitted envelope")
        pendingConsumed = ticket; transmitting = nil; preparedFrame = nil
        sourceReleaseRequired = true; receivedFrames += 1; activity = .idle
    }

    /// The native owner must actually drop its boundary, output enum, Send
    /// handle, aliases and enclosing autorelease scope before calling this.
    mutating func sentSourceReleased(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .idle && sourceReleaseRequired && pendingConsumed == ticket,
                    "Source release lacks completed payload send and received ACK")
        sourceReleaseRequired = false
    }

    mutating func beginConsumedDrain(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .idle && !sourceReleaseRequired && pendingConsumed == ticket,
                    "Consumed ACK drain overlaps preparation or lacks its pending envelope")
        activity = .drainingConsumed
    }

    /// Saved completion uses this ticket's capture, not the live native frontier:
    /// stage zero may already have committed the next prompt chunk at this point.
    mutating func consumedACKAccepted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .drainingConsumed && pendingConsumed == ticket,
                    "Consumed ACK differs from the pending envelope")
        completedFrames += 1; pendingConsumed = nil; activity = .idle
    }

    mutating func close() throws {
        if isClosed { return }
        try require(activity == .idle && completedFrames == plan.frames.count
            && producedFrames == completedFrames && receivedFrames == completedFrames
            && preparedFrame == nil && pendingConsumed == nil && !sourceReleaseRequired,
            "Sender closed before its final consumed ACK and residual release")
        activity = .closed
    }

    /// Fences bookkeeping only. The native owner must drop arrays, cancel its
    /// request, retire transport, and ask the parent to fence the peer process.
    mutating func retire() {
        activity = .failed; preparedFrame = nil; preparingFrame = nil
        transmitting = nil; pendingConsumed = nil; sourceReleaseRequired = false
    }

    private mutating func require(_ condition: Bool, _ reason: String) throws {
        guard condition && !isClosed && !isFailed else {
            retire(); throw ProbeError(reason)
        }
    }
}

import Foundation

/// Pure rank-one sequencing. Header, payload and ACK completion may block; this
/// machine requires only the local single-caller order, never eager buffering.
struct QwenLayerStageOverlapReceiver {
    enum Activity: String {
        case waitingHeader, receivingHeader, readyForReadyACK, sendingReadyACK
        case readyForPayload, receivingPayload, readyForReceivedACK, sendingReceivedACK
        case readyToConsume, consuming, consumedNeedsRelease, readyForConsumedACK
        case sendingConsumedACK, closed, failed
    }

    enum NextAction: Equatable {
        case receiveHeader, sendReadyACK(QwenLayerStageOverlapTicket)
        case receivePayload(QwenLayerStageOverlapTicket), sendReceivedACK(QwenLayerStageOverlapTicket)
        case consume(QwenLayerStageOverlapTicket), releaseBoundary(QwenLayerStageOverlapTicket)
        case sendConsumedACK(QwenLayerStageOverlapTicket), close, inProgress, unavailable
    }

    let plan: QwenLayerStageOverlapPlan
    private(set) var activity: Activity = .waitingHeader
    private(set) var committedFrames = 0
    private(set) var completedFrames = 0
    private(set) var ownsBoundary = false
    private(set) var current: QwenLayerStageOverlapTicket?

    init(plan: QwenLayerStageOverlapPlan) { self.plan = plan }

    var isFailed: Bool { activity == .failed }
    var isClosed: Bool { activity == .closed }
    var committedTokens: Int { plan.committedTokens(after: committedFrames) }

    var nextAction: NextAction {
        if activity == .waitingHeader { return completedFrames == plan.frames.count ? .close : .receiveHeader }
        guard !isFailed && !isClosed else { return .unavailable }
        guard let ticket = current else { return .inProgress }
        switch activity {
        case .readyForReadyACK: return .sendReadyACK(ticket)
        case .readyForPayload: return .receivePayload(ticket)
        case .readyForReceivedACK: return .sendReceivedACK(ticket)
        case .readyToConsume: return .consume(ticket)
        case .consumedNeedsRelease: return .releaseBoundary(ticket)
        case .readyForConsumedACK: return .sendConsumedACK(ticket)
        default: return .inProgress
        }
    }

    mutating func beginHeaderReceive() throws {
        try require(activity == .waitingHeader && !ownsBoundary && current == nil
            && completedFrames == committedFrames && plan.frames.indices.contains(committedFrames),
            "Receiver accepted another header before prior consumption, release and ACK completion")
        activity = .receivingHeader
    }

    /// Envelope flow/version, source identity, tokens and local geometry must
    /// already be validated. No payload allocation precedes this transition.
    mutating func headerValidated(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .receivingHeader && plan.matches(ticket, at: committedFrames),
                    "Receiver header differs from its exact next local frame")
        current = ticket; activity = .readyForReadyACK
    }

    mutating func beginReadyACK(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForReadyACK && current == ticket, "Ready ACK is out of order")
        activity = .sendingReadyACK
    }

    mutating func readyACKSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingReadyACK && current == ticket, "Ready ACK completion is out of order")
        activity = .readyForPayload
    }

    mutating func beginPayloadReceive(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForPayload && current == ticket && !ownsBoundary,
                    "Payload receive lacks ready ACK completion or an empty owner slot")
        activity = .receivingPayload
    }

    /// Recv completion + native unique/compact/zero-offset ownership, shape,
    /// dtype, logical bytes and payload SHA checks must all have succeeded.
    mutating func payloadReceivedAndValidated(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .receivingPayload && current == ticket && !ownsBoundary,
                    "Received payload is not the active validated boundary")
        ownsBoundary = true; activity = .readyForReceivedACK
    }

    mutating func beginReceivedACK(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForReceivedACK && current == ticket && ownsBoundary,
                    "Received ACK precedes ownership and payload validation")
        activity = .sendingReceivedACK
    }

    mutating func receivedACKSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingReceivedACK && current == ticket, "Received ACK completion is out of order")
        activity = .readyToConsume
    }

    mutating func beginConsumption(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyToConsume && current == ticket && ownsBoundary,
                    "Stage-one compute precedes completed received ACK")
        activity = .consuming
    }

    /// This is the end of the entire existing consume callback: native output
    /// and state roots commit, snapshot/logits copy, and throwing CPU observer.
    mutating func consumptionAndCaptureCompleted(_ ticket: QwenLayerStageOverlapTicket,
                                                 committedTokens: Int) throws {
        try require(activity == .consuming && current == ticket
            && committedTokens == ticket.frame.tokenOffset + ticket.frame.tokenCount,
            "Stage-one consumption/capture has the wrong committed frontier")
        committedFrames += 1; activity = .consumedNeedsRelease
    }

    mutating func consumedBoundaryReleased(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .consumedNeedsRelease && current == ticket && ownsBoundary,
                    "Receiver boundary release precedes committed consumption and capture")
        ownsBoundary = false; activity = .readyForConsumedACK
    }

    mutating func beginConsumedACK(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForConsumedACK && current == ticket && !ownsBoundary,
                    "Consumed ACK precedes local commit/capture or retains the explicit boundary")
        activity = .sendingConsumedACK
    }

    mutating func consumedACKSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingConsumedACK && current == ticket,
                    "Consumed ACK completion is out of order")
        completedFrames += 1; current = nil; activity = .waitingHeader
    }

    mutating func close() throws {
        if isClosed { return }
        try require(activity == .waitingHeader && completedFrames == plan.frames.count
            && committedFrames == completedFrames && !ownsBoundary && current == nil,
            "Receiver closed before final committed consumption, release and ACK completion")
        activity = .closed
    }

    /// Pure retirement never claims that native cleanup or peer exit completed.
    mutating func retire() { activity = .failed; ownsBoundary = false; current = nil }

    private mutating func require(_ condition: Bool, _ reason: String) throws {
        guard condition && !isClosed && !isFailed else {
            retire(); throw ProbeError(reason)
        }
    }
}

import Foundation

/// CPU-only event traces. A completed event is an assertion supplied by a
/// future native adapter; these checks do not claim transport or model parity.
enum QwenLayerStageOverlapTraceCheck {
    struct Result: Encodable {
        let ackCompletion: String
        let frameCount: Int
        let promptLookaheadCount: Int
        let maximumProducedMinusCompleted: Int
        let finalCommittedTokens: Int
    }

    static func run(plan: QwenLayerStageOverlapPlan, bufferedConsumedACK: Bool) throws -> Result {
        var sender = QwenLayerStageOverlapSender(plan: plan)
        var receiver = QwenLayerStageOverlapReceiver(plan: plan)
        var lookaheads = 0, maximumAhead = 0
        for frame in plan.frames {
            let ticket = try ticket(plan: plan, frame: frame)
            if sender.preparedFrame == nil {
                guard sender.nextAction == .prepare(frame) else { throw ProbeError("Trace lost its next preparation") }
                try sender.beginPreparation(frame)
                try sender.preparationCompleted(frame, committedTokens: end(frame))
            }
            guard sender.nextAction == .sendPrepared(frame) else { throw ProbeError("Trace lost its prepared output") }
            try deliver(ticket, sender: &sender, receiver: &receiver)
            try receiver.beginConsumption(ticket)
            if sender.canPrepareNext {
                let next = plan.frames[sender.producedFrames]
                guard next.phase == .prefill else { throw ProbeError("Trace admitted speculative decode") }
                try sender.beginPreparation(next)
                try completeConsumption(ticket, receiver: &receiver)
                if bufferedConsumedACK { try receiver.consumedACKSendCompleted(ticket) }
                try sender.preparationCompleted(next, committedTokens: end(next))
                guard sender.nextAction == .drainConsumed(ticket) else { throw ProbeError("Trace skipped consumed drain") }
                lookaheads += 1
                try validateCounters(sender, receiver)
                maximumAhead = max(maximumAhead, sender.producedFrames - sender.completedFrames)
                try sender.beginConsumedDrain(ticket)
                if !bufferedConsumedACK { try receiver.consumedACKSendCompleted(ticket) }
            } else {
                // Final prompt/decode frame drains immediately; the receiver
                // can finish native work while this synchronous receive waits.
                try sender.beginConsumedDrain(ticket)
                try completeConsumption(ticket, receiver: &receiver)
                try receiver.consumedACKSendCompleted(ticket)
                maximumAhead = max(maximumAhead, sender.producedFrames - sender.completedFrames)
            }
            try sender.consumedACKAccepted(ticket)
            try validateCounters(sender, receiver)
            guard sender.completedFrames == frame.sequence + 1,
                  receiver.completedFrames == frame.sequence + 1 else {
                throw ProbeError("Trace completion skipped or duplicated a frame")
            }
        }
        guard sender.nextAction == .close, receiver.nextAction == .close else {
            throw ProbeError("Trace did not require final drain before close")
        }
        try sender.close(); try receiver.close()
        guard sender.isClosed, receiver.isClosed, !sender.isFailed, !receiver.isFailed,
              sender.committedTokens == plan.finalCommittedTokens,
              receiver.committedTokens == plan.finalCommittedTokens else {
            throw ProbeError("Trace did not finish both exact frontiers")
        }
        return .init(ackCompletion: bufferedConsumedACK ? "buffered_before_peer_receive" : "blocked_until_peer_receive",
            frameCount: plan.frames.count, promptLookaheadCount: lookaheads,
            maximumProducedMinusCompleted: maximumAhead, finalCommittedTokens: sender.committedTokens)
    }

    static func ticket(plan: QwenLayerStageOverlapPlan, frame: QwenLayerStageFrame,
                       salt: String = "valid") throws -> QwenLayerStageOverlapTicket {
        try .init(flow: QwenLayerStageOverlapFlow.name, requestFingerprint: plan.requestFingerprint,
            frame: frame, headerSHA256: sha256(Data("pure-overlap-test-envelope|\(frame.sequence)|\(salt)".utf8)))
    }

    static func senderAfterReceived(plan: QwenLayerStageOverlapPlan,
                                    ticket: QwenLayerStageOverlapTicket,
                                    releaseSource: Bool) throws -> QwenLayerStageOverlapSender {
        var sender = QwenLayerStageOverlapSender(plan: plan)
        try sender.beginPreparation(ticket.frame)
        try sender.preparationCompleted(ticket.frame, committedTokens: end(ticket.frame))
        try sender.beginHeader(ticket); try sender.headerSendCompleted(ticket)
        try sender.readyACKAccepted(ticket); try sender.beginPayloadSend(ticket)
        try sender.payloadSendCompleted(ticket); try sender.receivedACKAccepted(ticket)
        if releaseSource { try sender.sentSourceReleased(ticket) }
        return sender
    }

    static func receiverAwaitingPayload(plan: QwenLayerStageOverlapPlan,
                                        ticket: QwenLayerStageOverlapTicket) throws -> QwenLayerStageOverlapReceiver {
        var receiver = QwenLayerStageOverlapReceiver(plan: plan)
        try receiver.beginHeaderReceive(); try receiver.headerValidated(ticket)
        try receiver.beginReadyACK(ticket); try receiver.readyACKSendCompleted(ticket)
        try receiver.beginPayloadReceive(ticket)
        return receiver
    }

    static func end(_ frame: QwenLayerStageFrame) -> Int { frame.tokenOffset + frame.tokenCount }

    private static func deliver(_ ticket: QwenLayerStageOverlapTicket,
                                sender: inout QwenLayerStageOverlapSender,
                                receiver: inout QwenLayerStageOverlapReceiver) throws {
        try sender.beginHeader(ticket); try receiver.beginHeaderReceive()
        try sender.headerSendCompleted(ticket); try receiver.headerValidated(ticket)
        try receiver.beginReadyACK(ticket); try sender.readyACKAccepted(ticket)
        try receiver.readyACKSendCompleted(ticket); try receiver.beginPayloadReceive(ticket)
        try sender.beginPayloadSend(ticket); try sender.payloadSendCompleted(ticket)
        try receiver.payloadReceivedAndValidated(ticket); try receiver.beginReceivedACK(ticket)
        try sender.receivedACKAccepted(ticket); try receiver.receivedACKSendCompleted(ticket)
        guard sender.nextAction == .releaseSentSource(ticket), receiver.nextAction == .consume(ticket) else {
            throw ProbeError("Trace lost its source-release or receiver-consumption boundary")
        }
        try sender.sentSourceReleased(ticket)
        try validateCounters(sender, receiver)
    }

    private static func completeConsumption(_ ticket: QwenLayerStageOverlapTicket,
                                           receiver: inout QwenLayerStageOverlapReceiver) throws {
        try receiver.consumptionAndCaptureCompleted(ticket, committedTokens: end(ticket.frame))
        try receiver.consumedBoundaryReleased(ticket); try receiver.beginConsumedACK(ticket)
    }

    private static func validateCounters(_ sender: QwenLayerStageOverlapSender,
                                         _ receiver: QwenLayerStageOverlapReceiver) throws {
        guard sender.completedFrames <= sender.receivedFrames,
              sender.receivedFrames <= sender.producedFrames,
              sender.receivedFrames - sender.completedFrames <= 1,
              sender.producedFrames - sender.receivedFrames <= 1,
              sender.producedFrames - sender.completedFrames <= 2,
              receiver.completedFrames <= receiver.committedFrames,
              receiver.committedFrames - receiver.completedFrames <= 1,
              receiver.committedFrames <= sender.receivedFrames else {
            throw ProbeError("Trace exceeded its one pending/one prepared frame bounds")
        }
    }
}

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

let result = try QwenLayerStageOverlapCheck.run()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
FileHandle.standardOutput.write(try encoder.encode(result))
FileHandle.standardOutput.write(Data([10]))
