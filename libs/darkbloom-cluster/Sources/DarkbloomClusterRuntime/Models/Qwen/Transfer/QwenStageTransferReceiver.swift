import Foundation

/// Where the receiving rank keeps arriving pieces, and what hashes them. The
/// native intake assembles each tensor in its final allocation and hashes it
/// in place; a check keeps host bytes. Either way it only stores and computes:
/// the receiver below decides what a digest means.
protocol QwenStageTransferIntake {
    associatedtype Payload
    /// One received piece. A tensor's pieces arrive consecutively, in axis-0
    /// order; the last has `index + 1 == tensor.pieces.upperBound`.
    mutating func accept(_ payload: Payload, for piece: QwenStageTransferPlan.Piece) throws
    /// The SHA-256 of the stored bytes of each tensor whose hashing finished
    /// since the last call, by plan tensor index. `joining` waits for every
    /// tensor that has fully arrived.
    mutating func completedDigests(joining: Bool) throws -> [(tensor: Int, contentSHA256: String)]
}

/// The receiving rank's side of a stage transfer, as a state machine with no
/// transport of its own. Every receive it asks for has a size, shape and dtype
/// it derived itself. A tensor counts only when the digest of what arrived
/// equals its pinned record, and the transfer is verified only when every
/// planned tensor has counted and the sender has closed.
final class QwenStageTransferReceiver<Intake: QwenStageTransferIntake> {
    enum Action {
        case sendControl([Int32])
        case receiveControl
        case receivePiece(QwenStageTransferPlan.Piece)
        case finished
    }

    private enum State {
        case awaitingOpen
        case opening(peer: [Int32])
        case validatingOpen(peer: [Int32])
        case awaitingWindow(Int)
        case receiving(window: Int, piece: Int)
        case windowBoundary(Int)
        case judging
        case awaitingClose
        case finished
        /// An abort has been handed out; the next call reports this failure.
        case failing(any Error)
        case failed
    }

    let session: QwenStageTransferSession
    private var intake: Intake
    private var watch: QwenStageTransferWatch
    private var state = State.awaitingOpen
    private var verified = Set<Int>()
    private(set) var receivedBytes = 0
    var isVerified: Bool { if case .finished = state { true } else { false } }

    init(session: QwenStageTransferSession, intake: Intake, watch: QwenStageTransferWatch) {
        self.session = session; self.intake = intake; self.watch = watch
    }

    /// What arrived, and only once every digest has passed and the sender has closed.
    func verifiedIntake() throws -> Intake {
        guard isVerified else { throw ProbeError("Stage transfer has not been verified") }
        return intake
    }

    func next() throws -> Action {
        do {
            // Ended states make no call, so they are not subject to the checks before one.
            switch state {
            case .failing(let failure): throw failure
            case .failed: throw ProbeError("Stage transfer receiver has already failed")
            case .finished: return .finished
            default: try watch.beforeCall()
            }
            let plan = session.plan
            switch state {
            case .awaitingOpen, .awaitingWindow, .awaitingClose:
                return .receiveControl
            case .opening(let peer):
                // Both ranks say their own value before either judges the other's.
                state = .validatingOpen(peer: peer)
                return .sendControl(control(.transferOpen, window: 0, bytes: 0))
            case .validatingOpen(let peer):
                guard peer == control(.transferOpen, from: .sender, window: 0, bytes: 0) else { throw Self.unexpected }
                watch.begin(budgetNanoseconds: plan.budgetNanoseconds)
                state = .awaitingWindow(0)
                return .receiveControl
            case .receiving(_, let index):
                return .receivePiece(plan.pieces[index])
            case .windowBoundary(let window):
                let received = plan.windows[window].precedingBytes + plan.windows[window].byteCount
                if watch.failure == nil {
                    do { try collectDigests(joining: false) } catch { watch.fail(error) }
                }
                if let failure = watch.failure {
                    state = .failing(failure)
                    return .sendControl(control(.receiverAbort, window: window, bytes: received))
                }
                state = window + 1 < plan.windows.count ? .awaitingWindow(window + 1) : .judging
                return .sendControl(control(.windowReceived, window: window, bytes: received))
            case .judging:
                if watch.failure == nil {
                    do {
                        try collectDigests(joining: true)
                        guard verified.count == plan.tensors.count else {
                            throw ProbeError("Stage transfer ended without a matching digest for every tensor")
                        }
                    } catch { watch.fail(error) }
                }
                state = .awaitingClose
                return .sendControl(control(watch.failure == nil ? .stageVerified : .stageRefused,
                    window: plan.windows.count, bytes: plan.payloadBytes))
            case .finished, .failing, .failed:
                throw ProbeError("Stage transfer receiver has no call left to make")
            }
        } catch { state = .failed; throw error }
    }

    func received(control values: [Int32]) throws {
        do {
            let plan = session.plan
            switch state {
            case .awaitingOpen:
                state = .opening(peer: values)
            case .awaitingWindow(let window):
                let preceding = plan.windows[window].precedingBytes
                if values == control(.windowOpen, from: .sender, window: window, bytes: preceding) {
                    state = .receiving(window: window, piece: plan.windows[window].pieces.lowerBound)
                } else if values == control(.senderAbort, from: .sender, window: window, bytes: preceding) {
                    throw watch.failure ?? ProbeError("The sending rank aborted the stage transfer")
                } else { throw Self.unexpected }
            case .awaitingClose:
                if values == control(.senderComplete, from: .sender, window: plan.windows.count, bytes: plan.payloadBytes) {
                    // A refused stage, or a budget that ran out before this last call.
                    if let failure = watch.failure { throw failure }
                    state = .finished
                } else if values == control(.senderAbort, from: .sender, window: plan.windows.count, bytes: plan.payloadBytes) {
                    throw watch.failure ?? ProbeError("The sending rank aborted the stage transfer")
                } else { throw Self.unexpected }
            default:
                throw ProbeError("Stage transfer receiver was given a control value it had not asked for")
            }
        } catch { state = .failed; throw error }
    }

    /// The payload of the piece `next()` asked for. After a local failure the
    /// rest of the window is still received, to stay in step, and dropped.
    func received(_ payload: Intake.Payload, for piece: QwenStageTransferPlan.Piece) throws {
        guard case .receiving(let window, let index) = state, piece.index == index else {
            state = .failed
            throw ProbeError("Stage transfer receiver was given a piece it had not asked for")
        }
        if watch.failure == nil {
            do { try intake.accept(payload, for: piece) } catch { watch.fail(error) }
        }
        receivedBytes += piece.byteCount
        state = index + 1 < session.plan.windows[window].pieces.upperBound
            ? .receiving(window: window, piece: index + 1) : .windowBoundary(window)
    }

    /// The caller's transport failed. Nothing more is sent or accepted.
    func abandon() { state = .failed }

    private static var unexpected: ProbeError {
        ProbeError("Stage transfer control value from the sending rank differs from every value expected here")
    }

    private func control(_ phase: QwenStageTransferControl.Phase, from role: QwenStageTransferRole = .receiver,
                         window: Int, bytes: Int) -> [Int32] {
        QwenStageTransferControl.values(session, phase, from: role, window: window, cumulativeBytes: bytes)
    }

    private func collectDigests(joining: Bool) throws {
        for digest in try intake.completedDigests(joining: joining) {
            guard session.records.indices.contains(digest.tensor),
                  digest.contentSHA256 == session.records[digest.tensor].contentSHA256 else {
                throw ProbeError("Stage tensor content differs from its pinned SHA-256")
            }
            verified.insert(digest.tensor)
        }
    }
}
