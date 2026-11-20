import Foundation

/// This policy is usable only by the pinned, synchronous P32/C16/O2 entry.
/// It changes the added EP temporaries; full trunk/state terms stay unchanged.
enum Gemma4ExpertTemporaryPolicy: String, Encodable {
    case adjacentSynchronousV1 = "gemma4_ep_adjacent_synchronous_temporaries_v1"

    var layerSlots: Int { 2 }
    var maximumFrameTokens: Int { 16 }
    var scalarHostBytes: Int { 4_096 }
}

enum Gemma4ExpertTemporaryWindowError: Error {
    case invalidFrameCount, failedOrOutOfOrder, missingEvaluationOrCompletion, incomplete
}

/// Scalar guard, not an array owner or a replacement request/transport state.
/// `inputEvaluated` must follow the existing eval(input, ids, weights) + check.
struct Gemma4ExpertTemporaryWindow {
    private let frames: Int
    private var nextFrame = 0, nextLayer = 0
    private var entered = false, evaluated = false, exchanged = false, failed = false

    init(frames: Int) throws {
        guard frames == 2 || frames == 3 else {
            throw Gemma4ExpertTemporaryWindowError.invalidFrameCount
        }
        self.frames = frames
    }

    mutating func begin(frame: Int, layer: Int) throws {
        guard !failed, !entered, nextFrame < frames,
              frame == nextFrame, layer == nextLayer else {
            failed = true; throw Gemma4ExpertTemporaryWindowError.failedOrOutOfOrder
        }
        entered = true; evaluated = false; exchanged = false
    }

    mutating func inputEvaluated() throws {
        guard !failed, entered, !evaluated else {
            failed = true; throw Gemma4ExpertTemporaryWindowError.failedOrOutOfOrder
        }
        evaluated = true
    }

    mutating func exchangeCompleted() throws {
        guard !failed, entered, evaluated, !exchanged else {
            failed = true; throw Gemma4ExpertTemporaryWindowError.failedOrOutOfOrder
        }
        exchanged = true
    }

    mutating func returned() throws {
        guard !failed, entered, evaluated, exchanged else {
            failed = true; throw Gemma4ExpertTemporaryWindowError.missingEvaluationOrCompletion
        }
        entered = false; evaluated = false; exchanged = false
        nextLayer += 1
        if nextLayer == 30 { nextLayer = 0; nextFrame += 1 }
    }

    mutating func poison() { failed = true }

    func requireComplete() throws {
        guard !failed, !entered, !evaluated, !exchanged, nextFrame == frames, nextLayer == 0 else {
            throw Gemma4ExpertTemporaryWindowError.incomplete
        }
    }
}
