import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// A running request's live memory gate refused it (`requireContinuing`,
/// `requireLive`): what it still needs is more than the host admits now.
/// Typed so a stage's stop latch can tell it from every other failure of the
/// running check (power, thermal, a native error), which still ends the worker.
struct QwenResidentMemoryRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// One running request's stop latch on one rank of a layer-stage pipeline
/// (D6). The running memory check is not thrown from inside a transfer or a
/// forward any more, where a throw left the peer blocked in a receive and the
/// data plane unknown, so the worker had to exit. It is polled here, at the
/// points where this rank is about to send its peer the next message or to
/// run a forward (`QwenLayerStageGenerationTransport`, the drivers), and a
/// memory refusal is latched: the rank then stops in the slot it owes.
///
/// `evaluate` is the request's running check (`checkRunning`: kept prefixes
/// give way first, then the request's own capture), run at most once per
/// `intervalNanoseconds`, as the running check was. A `QwenResidentMemoryRefusal`
/// latches; any other error is thrown to the caller, which fails the request
/// as before. Once latched, the latch stays set and asks nothing more.
final class QwenStageAbort {
    let rank: Int
    private let intervalNanoseconds: UInt64
    private let evaluate: () throws -> Void
    private var lastPoll: UInt64 = 0
    private(set) var latched: ClusterWorkerAbort?
    /// The gate's own sentence, for whoever launched the worker.
    private(set) var reason: String?

    init(rank: Int, intervalNanoseconds: UInt64 = 250_000_000, evaluate: @escaping () throws -> Void) {
        self.rank = rank; self.intervalNanoseconds = intervalNanoseconds; self.evaluate = evaluate
    }

    /// True when this rank must stop the request now.
    @discardableResult func poll() throws -> Bool {
        if latched != nil { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastPoll == 0 || now &- lastPoll >= intervalNanoseconds else { return false }
        lastPoll = now
        do { try evaluate() } catch let refusal as QwenResidentMemoryRefusal {
            latched = .init(reason: .memory, rank: rank); reason = refusal.message
            log("darkbloom-stage-abort-v1 rank=\(rank) reason=memory: \(refusal.message)")
            return true
        }
        lastPoll = DispatchTime.now().uptimeNanoseconds
        return false
    }
}

/// The request ended on both ranks alone: this rank stopped in the slot it
/// owed (`local`), or its peer did and this rank confirmed. Thrown by the
/// transport once the confirmation is through; the driver then retires the
/// request with its peer (`exchangeAbortRetirement`) and reports `abort`.
struct QwenStageAborted: Error, CustomStringConvertible {
    let abort: ClusterWorkerAbort
    let local: Bool
    var description: String {
        "The pair ended this request alone: rank \(abort.rank)'s \(abort.reason.rawValue) refused it while it ran"
    }
}

/// Where a rank stops: the message it owes its peer next, which the marker
/// replaces in that message's own record (type, label and size).
enum QwenStageAbortSlot: Equatable {
    /// A length-prefixed control message (`sendData`): the boundary header,
    /// the target token, the generation decision.
    case data(ClusterRecordType, String)
    /// An acknowledgement (`sendAck`): ready, consumed, token, decision,
    /// hand-off ready or accepted.
    case acknowledgement
    /// A fixed control frame (`QwenControlFrame`) of `frameBytes`.
    case frame(frameBytes: Int, ClusterRecordType, String)
    /// Compact decode's combined residual frame, sized by the request.
    case compactBoundary
    /// Rank 0 at a frame's start: the boundary header it sends next.
    static let boundaryHeader = Self.data(.residualHeader, "boundary")
}

/// The markers and the confirmation. Each marker is a value the message it
/// replaces can never take, so a receiver tells them apart before decoding.
enum QwenStageAbortWire {
    /// A length word past every control body or header bound.
    static let lengthMarker: UInt32 = 0xFFFF_FFF1

    struct Packet: Encodable, Equatable {
        let schema = "qwen_stage_generation_abort_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let reason: String
        let rank: Int
    }

    /// The frame body that stands in a fixed frame.
    static func packet(agreement: QwenLayerStageGenerationAgreement, abort: ClusterWorkerAbort) throws -> Data {
        try canonicalJSONData(Packet(agreementFingerprint: agreement.fingerprint,
            membershipEpoch: agreement.descriptor.membershipEpoch, requestFingerprint: agreement.request.fingerprint,
            reason: abort.reason.rawValue, rank: abort.rank))
    }

    /// The abort a frame body carries; nil for any other body. A marker for
    /// another request or membership is refused.
    static func abort(in body: Data, agreement: QwenLayerStageGenerationAgreement) throws -> ClusterWorkerAbort? {
        // A residual frame's body starts with its binary header length, never `{`.
        guard body.first == UInt8(ascii: "{"),
              let object = try? QwenLayerStageGenerationWireJSON.object(body, maximumBytes: 4096),
              object["schema"] as? String == "qwen_stage_generation_abort_v1" else { return nil }
        guard let spelling = object["reason"] as? String, let reason = ClusterWorkerAbortReason(rawValue: spelling),
              let rank = BoundedProbeInput.integer(object["rank"]), (0...1).contains(rank) else {
            throw ProbeError("Generation abort marker is malformed")
        }
        let abort = ClusterWorkerAbort(reason: reason, rank: rank)
        try QwenLayerStageGenerationWireJSON.requireExact(object, Packet(agreementFingerprint: agreement.fingerprint,
            membershipEpoch: agreement.descriptor.membershipEpoch, requestFingerprint: agreement.request.fingerprint,
            reason: reason.rawValue, rank: rank))
        return abort
    }

    /// The marker in an acknowledgement slot, from `rank` (its sender, the
    /// rank that stops). Memory is the only reason in the closed set.
    static func acknowledgement(agreement: QwenLayerStageGenerationAgreement, rank: Int) throws -> [Int32] {
        try QwenLayerStageGenerationAcknowledgement.values(agreement: agreement, phase: .abortedMemory,
            packetFingerprint: agreement.fingerprint, rank: rank)
    }

    /// The one confirmation the receiver of a marker sends, from `rank`.
    static func confirmation(agreement: QwenLayerStageGenerationAgreement, rank: Int) throws -> [Int32] {
        try QwenLayerStageGenerationAcknowledgement.values(agreement: agreement, phase: .abortConfirmed,
            packetFingerprint: agreement.fingerprint, rank: rank)
    }

    /// What both ranks' retirement acknowledgements bind for an aborted request.
    static func retirementFingerprint(agreement: QwenLayerStageGenerationAgreement,
                                      abort: ClusterWorkerAbort) throws -> String {
        try qwenGenerationFingerprint("abort", Packet(agreementFingerprint: agreement.fingerprint,
            membershipEpoch: agreement.descriptor.membershipEpoch, requestFingerprint: agreement.request.fingerprint,
            reason: abort.reason.rawValue, rank: abort.rank))
    }
}
