import Foundation
import MLX

/// A stage whose tensors arrive by transfer. The loader sees none of them
/// until `receive` has returned an intake the receiver verified in full, and
/// that intake has already passed each one through the load's gate.
final class QwenStageTransferredPayload: QwenLayerStagePayloadSource {
    typealias Receive = ([QwenStageActiveTensor], any QwenLayerStageGate) throws -> QwenStageNativeIntake
    private let receive: Receive
    private var delivered: (index: [String: Int], intake: QwenStageNativeIntake)?

    init(receive: @escaping Receive) { self.receive = receive }

    func begin(_ active: [QwenStageActiveTensor], gate: any QwenLayerStageGate) throws {
        let intake = try receive(active, gate)
        delivered = (Dictionary(uniqueKeysWithValues: intake.plan.tensors.enumerated().map { ($0.element.sourceName, $0.offset) }),
                     intake)
    }

    /// The gate was asked when the tensor arrived, so `beforeRead` is not called again.
    func tensor(_ entry: QwenStageActiveTensor,
                beforeRead: (QwenStageActiveTensor) throws -> Void) throws -> QwenLayerStagePayload {
        guard let delivered, let index = delivered.index[entry.sourceName], let array = delivered.intake.take(index) else {
            throw ProbeError("Transferred stage has no such tensor")
        }
        return .init(array: array, copiedBytes: array.nbytes, largestHostTensorBytes: array.nbytes, readAccounting: nil)
    }

    func finish() throws {
        guard delivered?.intake.heldTensorCount == 0 else {
            throw ProbeError("Transferred stage holds tensors the loader did not take")
        }
    }
}
