import Foundation
import MLX

/// One native MLX owner per process; every public operation is synchronous,
/// non-reentrant and permanently poisoned on error. No clock/context/model is
/// created here. The driver owns source admission, preparation order and cleanup.
/// Phase callbacks record CPU metadata only; check only checks/throws. The
/// receive consumer is the sole callback allowed to execute the admitted model.
/// No concurrent model/transport evaluation may occur in this process.
final class QwenLayerStageProfiledPrefillTransport {
    let agreement: QwenLayerStageProfiledPrefillStartAgreement
    let rank: Int
    // Internal access permits focused implementation extensions in other files.
    // Progress mutation remains encapsulated behind the guarded state methods.
    let state: QwenLayerStageProfiledPrefillTransportState
    let io: QwenLayerStageProfiledPrefillNativeIO

    var isFailed: Bool { state.isFailed }
    var startCompleted: Bool { state.startCompleted }
    var hasPendingConsumption: Bool { state.hasPendingConsumption }
    var completedBoundaryCount: Int { state.completedBoundaryCount }
    var tokenTransferCompleted: Bool { state.tokenTransferCompleted }
    var postStopReleaseCompleted: Bool { state.postStopReleaseCompleted }
    var isComplete: Bool { state.isComplete }

    init(collective: Collective, agreement: QwenLayerStageProfiledPrefillStartAgreement, admittedRank: Int) throws {
        guard (0..<2).contains(admittedRank), collective.rank == admittedRank, collective.size == 2 else {
            throw ProbeError("Profiled prefill transport differs from its admitted rank and two-process group")
        }
        self.agreement = agreement; self.rank = admittedRank
        state = .init(rank: admittedRank, agreement: agreement)
        io = .init(collective: collective)
    }

    /// No native call: it cannot interrupt a peer blocked inside its backend.
    func retire() { state.retire() }

    func operation<T>(_ body: () throws -> T) throws -> T {
        try state.beginOperation()
        defer { state.endOperation() }
        do {
            return try MLX.withError { error in
                try error.check(); try state.requireActive()
                let result = try body()
                try error.check(); try state.requireActive()
                return result
            }
        } catch { state.retire(); throw error }
    }

    func checked(_ check: () throws -> Void) throws {
        try state.requireActive(); try check(); try state.requireActive()
    }
}
