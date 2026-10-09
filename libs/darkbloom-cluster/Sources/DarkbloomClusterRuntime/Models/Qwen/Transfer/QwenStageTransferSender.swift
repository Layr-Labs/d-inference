import Foundation

/// Stored bytes of the sending rank's verified artifact, one planned piece at
/// a time. The sender never holds more than the piece it is about to send.
protocol QwenStageTransferByteSource {
    associatedtype Payload
    /// `piece.byteCount` bytes of `file` from `offset`, as one message of the
    /// piece's shape and dtype.
    func read(_ piece: QwenStageTransferPlan.Piece, file: String, offset: Int) throws -> Payload
    /// A message of the same geometry that carries no artifact bytes. It is
    /// sent only to keep a window whole once the sender has already failed.
    func placeholder(_ piece: QwenStageTransferPlan.Piece) throws -> Payload
}

/// The sending rank's side of a stage transfer, as a state machine with no
/// transport of its own: `next()` names the one call to make, and the caller
/// reports what a receive returned. It serves pinned byte ranges and learns
/// nothing from the receiver but fixed control values.
final class QwenStageTransferSender<Source: QwenStageTransferByteSource> {
    enum Action {
        case sendControl([Int32])
        case sendPiece(QwenStageTransferPlan.Piece, Source.Payload)
        case receiveControl
        case finished
    }

    private enum State {
        case opening, awaitingOpen
        case windowBoundary(Int)
        case sending(window: Int, piece: Int)
        case awaitingWindow(Int)
        case awaitingVerdict
        case closing(refused: Bool)
        case finishing, finished
        /// An abort has been handed out; the next call reports this failure.
        case failing(any Error)
        case failed
    }

    let session: QwenStageTransferSession
    private let source: Source
    private var watch: QwenStageTransferWatch
    private var state = State.opening
    /// Artifact bytes handed to the transport; placeholders are not counted.
    private(set) var servedBytes = 0
    var isFinished: Bool { if case .finished = state { true } else { false } }

    init(session: QwenStageTransferSession, source: Source, watch: QwenStageTransferWatch) {
        self.session = session; self.source = source; self.watch = watch
    }

    func next() throws -> Action {
        do {
            // Ended states make no call, so they are not subject to the checks before one.
            switch state {
            case .failing(let failure): throw failure
            case .failed: throw ProbeError("Stage transfer sender has already failed")
            case .finishing, .finished: state = .finished; return .finished
            default: try watch.beforeCall()
            }
            let plan = session.plan
            switch state {
            case .opening:
                state = .awaitingOpen
                return .sendControl(control(.transferOpen, window: 0, bytes: 0))
            case .awaitingOpen, .awaitingWindow, .awaitingVerdict:
                return .receiveControl
            case .windowBoundary(let window):
                let preceding = plan.windows[window].precedingBytes
                if let failure = watch.failure {
                    state = .failing(failure)
                    return .sendControl(control(.senderAbort, window: window, bytes: preceding))
                }
                state = .sending(window: window, piece: plan.windows[window].pieces.lowerBound)
                return .sendControl(control(.windowOpen, window: window, bytes: preceding))
            case .sending(let window, let index):
                let piece = plan.pieces[index]
                state = index + 1 < plan.windows[window].pieces.upperBound
                    ? .sending(window: window, piece: index + 1) : .awaitingWindow(window)
                return .sendPiece(piece, try payload(piece))
            case .closing(let refused):
                if let failure = watch.failure {
                    state = .failing(failure)
                    return .sendControl(control(.senderAbort, window: plan.windows.count, bytes: plan.payloadBytes))
                }
                state = refused ? .failing(ProbeError("The receiving rank refused the transferred stage")) : .finishing
                return .sendControl(control(.senderComplete, window: plan.windows.count, bytes: plan.payloadBytes))
            case .finishing, .finished, .failing, .failed:
                throw ProbeError("Stage transfer sender has no call left to make")
            }
        } catch { state = .failed; throw error }
    }

    func received(control values: [Int32]) throws {
        do {
            let plan = session.plan
            switch state {
            case .awaitingOpen:
                guard values == control(.transferOpen, from: .receiver, window: 0, bytes: 0) else { throw Self.unexpected }
                watch.begin(budgetNanoseconds: plan.budgetNanoseconds)
                state = .windowBoundary(0)
            case .awaitingWindow(let window):
                let received = plan.windows[window].precedingBytes + plan.windows[window].byteCount
                if values == control(.windowReceived, from: .receiver, window: window, bytes: received) {
                    state = window + 1 < plan.windows.count ? .windowBoundary(window + 1) : .awaitingVerdict
                } else if values == control(.receiverAbort, from: .receiver, window: window, bytes: received) {
                    throw watch.failure ?? ProbeError("The receiving rank aborted the stage transfer")
                } else { throw Self.unexpected }
            case .awaitingVerdict:
                if values == control(.stageVerified, from: .receiver, window: plan.windows.count, bytes: plan.payloadBytes) {
                    state = .closing(refused: false)
                } else if values == control(.stageRefused, from: .receiver, window: plan.windows.count, bytes: plan.payloadBytes) {
                    state = .closing(refused: true)
                } else { throw Self.unexpected }
            default:
                throw ProbeError("Stage transfer sender was given a control value it had not asked for")
            }
        } catch { state = .failed; throw error }
    }

    /// The caller's transport failed. Nothing more is sent or accepted.
    func abandon() { state = .failed }

    private static var unexpected: ProbeError {
        ProbeError("Stage transfer control value from the receiving rank differs from every value expected here")
    }

    private func control(_ phase: QwenStageTransferControl.Phase, from role: QwenStageTransferRole = .sender,
                         window: Int, bytes: Int) -> [Int32] {
        QwenStageTransferControl.values(session, phase, from: role, window: window, cumulativeBytes: bytes)
    }

    /// The piece's pinned byte range, or a placeholder once this rank has
    /// failed: the receiver is already waiting for exactly this many bytes.
    private func payload(_ piece: QwenStageTransferPlan.Piece) throws -> Source.Payload {
        if watch.failure == nil {
            do {
                let location = session.records[piece.tensor].source
                let payload = try source.read(piece, file: location.sourceFile,
                    offset: location.sourceOffset + piece.byteOffset)
                servedBytes += piece.byteCount
                return payload
            } catch { watch.fail(error) }
        }
        return try source.placeholder(piece)
    }
}
