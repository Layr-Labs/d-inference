import Foundation

/// The point-to-point link a stage transfer runs over. A receive names the
/// planned piece, so its size, shape and dtype are this rank's own. Every call
/// blocks until it completes or throws.
protocol QwenStageTransferTransport {
    associatedtype Payload
    func send(control values: [Int32]) throws
    func receiveControl() throws -> [Int32]
    func send(_ payload: Payload, as piece: QwenStageTransferPlan.Piece) throws
    func receive(_ piece: QwenStageTransferPlan.Piece) throws -> Payload
}

extension QwenStageTransferSender {
    /// Serves the whole transfer over a blocking transport. A transport
    /// failure ends it at once; the peer finds out at its progress limit.
    func run<Transport: QwenStageTransferTransport>(over transport: Transport) throws
    where Transport.Payload == Source.Payload {
        while true {
            let action = try next()
            do {
                switch action {
                case .sendControl(let values): try transport.send(control: values)
                case .sendPiece(let piece, let payload): try transport.send(payload, as: piece)
                case .receiveControl: try received(control: transport.receiveControl())
                case .finished: return
                }
            } catch { abandon(); throw error }
        }
    }
}

extension QwenStageTransferReceiver {
    /// Receives the whole transfer over a blocking transport and returns only
    /// when every tensor has been verified and the sender has closed.
    func run<Transport: QwenStageTransferTransport>(over transport: Transport) throws
    where Transport.Payload == Intake.Payload {
        while true {
            let action = try next()
            do {
                switch action {
                case .sendControl(let values): try transport.send(control: values)
                case .receiveControl: try received(control: transport.receiveControl())
                case .receivePiece(let piece): try received(transport.receive(piece), for: piece)
                case .finished: return
                }
            } catch { abandon(); throw error }
        }
    }
}
