import Foundation

/// Two byte streams with no message boundaries, as on the real link: a receive
/// takes exactly the bytes it asked for, whatever the peer meant them to be.
/// Both state machines run on this one thread, each stepped while it can move.
final class LoopbackLink {
    enum Message: Equatable {
        case control([Int32])
        case piece(Int)
    }

    /// What each end put on the link, before any rewriting below.
    private(set) var fromSender: [Message] = [], fromReceiver: [Message] = []
    private(set) var pieceBytesFromSender = 0
    /// Rewrites the bytes of a rank's n-th message, as a wrong peer would send them.
    var rewriteFromSender: (Int, [UInt8]) -> [UInt8] = { $1 }
    var rewriteFromReceiver: (Int, [UInt8]) -> [UInt8] = { $1 }
    /// Runs before each sender or receiver step, with the messages each has sent so far.
    var beforeStep: (_ fromSender: Int, _ fromReceiver: Int) -> Void = { _, _ in }
    private var toReceiver: [UInt8] = [], toSender: [UInt8] = []

    struct Outcome {
        let sender: (any Error)?, receiver: (any Error)?
        var senderText: String { sender.map { String(describing: $0) } ?? "finished" }
        var receiverText: String { receiver.map { String(describing: $0) } ?? "finished" }
    }

    static let stalled = "no progress: the peer stopped sending (the collective progress limit on the real link)"

    static func bytes(_ values: [Int32]) -> [UInt8] {
        values.flatMap { value in withUnsafeBytes(of: value.littleEndian) { Array($0) } }
    }

    private static func take(_ count: Int, from stream: inout [UInt8]) -> [UInt8]? {
        guard stream.count >= count else { return nil }
        defer { stream.removeFirst(count) }
        return Array(stream.prefix(count))
    }

    private static func control(from stream: inout [UInt8]) -> [Int32]? {
        take(QwenStageTransferControl.valueCount * 4, from: &stream).map { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { index in
                Int32(littleEndian: bytes[index..<(index + 4)].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            }
        }
    }

    func exchange<Source: QwenStageTransferByteSource, Intake: QwenStageTransferIntake>(
        _ sender: QwenStageTransferSender<Source>, _ receiver: QwenStageTransferReceiver<Intake>
    ) -> Outcome where Source.Payload == Data, Intake.Payload == Data {
        var senderAction: QwenStageTransferSender<Source>.Action?
        var receiverAction: QwenStageTransferReceiver<Intake>.Action?
        var senderDone = false, receiverDone = false
        var senderError: (any Error)?, receiverError: (any Error)?
        while !senderDone || !receiverDone {
            var progressed = false
            if !senderDone {
                beforeStep(fromSender.count, fromReceiver.count)
                do {
                    let action = try senderAction ?? sender.next()
                    senderAction = action
                    switch action {
                    case .sendControl(let values):
                        toReceiver += rewriteFromSender(fromSender.count, Self.bytes(values))
                        fromSender.append(.control(values))
                        senderAction = nil; progressed = true
                    case .sendPiece(let piece, let payload):
                        toReceiver += rewriteFromSender(fromSender.count, Array(payload))
                        fromSender.append(.piece(piece.index)); pieceBytesFromSender += payload.count
                        senderAction = nil; progressed = true
                    case .receiveControl:
                        guard let values = Self.control(from: &toSender) else { break }
                        senderAction = nil; progressed = true
                        try sender.received(control: values)
                    case .finished:
                        senderDone = true; progressed = true
                    }
                } catch { senderError = error; senderDone = true; progressed = true }
            }
            if !receiverDone {
                beforeStep(fromSender.count, fromReceiver.count)
                do {
                    let action = try receiverAction ?? receiver.next()
                    receiverAction = action
                    switch action {
                    case .sendControl(let values):
                        toSender += rewriteFromReceiver(fromReceiver.count, Self.bytes(values))
                        fromReceiver.append(.control(values))
                        receiverAction = nil; progressed = true
                    case .receiveControl:
                        guard let values = Self.control(from: &toReceiver) else { break }
                        receiverAction = nil; progressed = true
                        try receiver.received(control: values)
                    case .receivePiece(let piece):
                        guard let bytes = Self.take(piece.byteCount, from: &toReceiver) else { break }
                        receiverAction = nil; progressed = true
                        try receiver.received(Data(bytes), for: piece)
                    case .finished:
                        receiverDone = true; progressed = true
                    }
                } catch { receiverError = error; receiverDone = true; progressed = true }
            }
            if !progressed {
                // Each remaining rank is inside a receive whose bytes will never come.
                if !senderDone { sender.abandon(); senderError = ProbeError(Self.stalled); senderDone = true }
                if !receiverDone { receiver.abandon(); receiverError = ProbeError(Self.stalled); receiverDone = true }
            }
        }
        return Outcome(sender: senderError, receiver: receiverError)
    }
}

/// Replays one rank's recorded messages to the other through the blocking
/// transport, to drive `run(over:)` on one thread.
final class ScriptedTransport: QwenStageTransferTransport {
    private var incoming: [LoopbackLink.Message]
    private let content: (QwenStageTransferPlan.Piece) -> Data
    private(set) var sent: [LoopbackLink.Message] = []

    init(incoming: [LoopbackLink.Message], content: @escaping (QwenStageTransferPlan.Piece) -> Data) {
        self.incoming = incoming; self.content = content
    }

    func send(control values: [Int32]) throws { sent.append(.control(values)) }
    func send(_ payload: Data, as piece: QwenStageTransferPlan.Piece) throws { sent.append(.piece(piece.index)) }

    func receiveControl() throws -> [Int32] {
        guard case .control(let values)? = incoming.first else { throw ProbeError("scripted transport has no control value") }
        incoming.removeFirst()
        return values
    }

    func receive(_ piece: QwenStageTransferPlan.Piece) throws -> Data {
        guard incoming.first == .piece(piece.index) else { throw ProbeError("scripted transport has no such piece") }
        incoming.removeFirst()
        return content(piece)
    }
}
