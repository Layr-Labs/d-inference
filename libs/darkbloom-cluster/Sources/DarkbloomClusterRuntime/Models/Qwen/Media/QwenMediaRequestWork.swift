import Foundation
import MLX

/// Reservation-owned work, including partially evaluated arrays on failure.
/// Neither cancellation nor a failed forward releases its host/native charge.
final class QwenMediaRequestWork {
    let state: QwenMediaRequestState
    let budget: QwenMediaBudget
    let preparation = QwenMediaPreparation()
    var roots: [MLXArray] = []

    init(state: QwenMediaRequestState, budget: QwenMediaBudget) {
        self.state = state; self.budget = budget
    }
    /// Called on the native executor. The enclosing worker's fixed process
    /// deadline bounds a decoder that does not honor cooperative cancellation.
    func finishHostPreparation() {
        preparation.cancel()
        while !preparation.finished { Thread.sleep(forTimeInterval: 0.005) }
    }
    func releaseAfterCheckedDrain() throws {
        guard preparation.releaseIfFinished() else {
            throw ProbeError("Qwen media producer is still holding admitted host memory")
        }
        roots.removeAll()
        state.releaseAfterCheckedDrain()
    }
}
