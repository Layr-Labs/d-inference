import Foundation
import MLX

/// One source tensor in its stored dtype, and what supplying it cost.
struct QwenLayerStagePayload {
    let array: MLXArray
    let copiedBytes: Int
    let largestHostTensorBytes: Int
    /// Present when the tensor was read from a verified file.
    let readAccounting: CheckpointAlignedReadAccounting?
}

/// The ordered resource gate of one stage load. Whoever is about to give an
/// active tensor its storage asks it first, in the order of the stage's active
/// inventory; it asks the host memory policy and the allocator limit for
/// everything still to come.
protocol QwenLayerStageGate: AnyObject {
    /// Before the next active tensor has its storage.
    func beforeRead(_ entry: QwenStageActiveTensor) throws
    /// After an allocation has settled.
    func observe() throws
}

/// Where a stage's source tensors come from. The loader derives every name,
/// shape, dtype and byte count from metadata and checks each array it is
/// given against them; a payload source only supplies the bytes. It is also
/// the one that asks the load's gate, because it is the one that allocates.
protocol QwenLayerStagePayloadSource {
    /// Once, after every admission check and before the first tensor, with the
    /// stage's active inventory in the order the tensors will be asked for. A
    /// source whose tensors take their storage here passes each through `gate` first.
    func begin(_ active: [QwenStageActiveTensor], gate: any QwenLayerStageGate) throws
    /// The whole source tensor of one active entry. A source that gives the
    /// tensor its storage here calls `beforeRead` once it knows it has the tensor.
    func tensor(_ entry: QwenStageActiveTensor,
                beforeRead: (QwenStageActiveTensor) throws -> Void) throws -> QwenLayerStagePayload
    /// Once, after the last tensor.
    func finish() throws
}

/// This Mac's verified artifact: each tensor is one aligned, uncached read
/// through its pinned descriptor.
struct QwenVerifiedCheckpointPayload: QwenLayerStagePayloadSource {
    let checkpoint: VerifiedCheckpoint
    let canonical: [String: QwenCheckpointTensor<TensorDescriptor>]

    func begin(_ active: [QwenStageActiveTensor], gate: any QwenLayerStageGate) throws {
        try checkpoint.checkUnchanged()
        try checkpoint.bypassTensorPayloadCache()
    }

    func tensor(_ entry: QwenStageActiveTensor,
                beforeRead: (QwenStageActiveTensor) throws -> Void) throws -> QwenLayerStagePayload {
        guard let tensor = canonical[entry.sourceName] else { throw ProbeError("Verified stage descriptor disappeared") }
        try beforeRead(entry)
        let read = try tensor.read(.all)
        guard let accounting = read.readAccounting, accounting.selectedBytes == read.copiedBytes else {
            throw ProbeError("Selected-stage aligned read accounting is incomplete")
        }
        return .init(array: read.array, copiedBytes: read.copiedBytes,
                     largestHostTensorBytes: read.largestHostTensorBytes, readAccounting: accounting)
    }

    func finish() throws { try checkpoint.checkUnchanged() }
}
