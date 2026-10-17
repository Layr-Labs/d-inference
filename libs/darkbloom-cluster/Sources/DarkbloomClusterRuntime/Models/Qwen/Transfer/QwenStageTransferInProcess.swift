import Foundation
import MLX

/// Both ends of a transfer in one process, on one thread, with no collective:
/// each receive the receiver makes steps the sender until that message exists,
/// so at most one piece is ever in flight and nothing is copied on the way.
final class QwenStageTransferInProcessLink<Source: QwenStageTransferByteSource>: QwenStageTransferTransport {
    private let sender: QwenStageTransferSender<Source>
    private var toSender: [[Int32]] = []
    private var controls: [[Int32]] = []
    private var pieces: [(index: Int, payload: Source.Payload)] = []

    init(sender: QwenStageTransferSender<Source>) { self.sender = sender }

    func send(control values: [Int32]) throws { toSender.append(values) }

    func send(_ payload: Source.Payload, as piece: QwenStageTransferPlan.Piece) throws {
        throw ProbeError("An in-process stage transfer carries pieces toward the receiver only")
    }

    func receiveControl() throws -> [Int32] {
        while controls.isEmpty {
            guard pieces.isEmpty else { throw ProbeError("In-process stage transfer: a piece arrived where a control value belongs") }
            try step()
        }
        return controls.removeFirst()
    }

    func receive(_ piece: QwenStageTransferPlan.Piece) throws -> Source.Payload {
        while pieces.isEmpty {
            guard controls.isEmpty else { throw ProbeError("In-process stage transfer: a control value arrived where a piece belongs") }
            try step()
        }
        let next = pieces.removeFirst()
        guard next.index == piece.index else { throw ProbeError("In-process stage transfer: pieces out of order") }
        return next.payload
    }

    /// After the receiver has returned: the sender takes its last value and
    /// finishes, and nothing either end said is left unheard.
    func finishSender() throws {
        while !sender.isFinished { try step(senderMayFinish: true) }
        guard toSender.isEmpty, controls.isEmpty, pieces.isEmpty else {
            throw ProbeError("In-process stage transfer ended with a message nobody took")
        }
    }

    private func step(senderMayFinish: Bool = false) throws {
        switch try sender.next() {
        case .sendControl(let values): controls.append(values)
        case .sendPiece(let piece, let payload): pieces.append((piece.index, payload))
        case .receiveControl:
            guard !toSender.isEmpty else { throw ProbeError("In-process stage transfer made no progress") }
            try sender.received(control: toSender.removeFirst())
        case .finished:
            guard senderMayFinish else { throw ProbeError("In-process stage transfer: the sender finished while the receiver waited") }
        }
    }
}

/// One whole transfer in this process: a sender over `source`, a receiver into
/// a native intake under the load's `gate`, the pinned inventory deciding.
/// Returns only a verified intake.
func runQwenStageTransferInProcess<Source: QwenStageTransferByteSource>(
    session: QwenStageTransferSession, source: Source, active: [QwenStageActiveTensor],
    gate: any QwenLayerStageGate, hashThreads: Int = QwenStageNativeIntake.hashThreadCount,
    watch: () -> QwenStageTransferWatch, check: @escaping () throws -> Void
) throws -> QwenStageNativeIntake where Source.Payload == MLXArray {
    let sender = QwenStageTransferSender(session: session, source: source, watch: watch())
    let receiver = QwenStageTransferReceiver(session: session,
        intake: try QwenStageNativeIntake(plan: session.plan, active: active, gate: gate,
                                          hashThreads: hashThreads, check: check), watch: watch())
    let link = QwenStageTransferInProcessLink(sender: sender)
    do { try receiver.run(over: link) } catch { sender.abandon(); throw error }
    try link.finishSender()
    return try receiver.verifiedIntake()
}
