import Foundation
import MLX

enum QwenPhaseSplitArrays {
    static func dtype(_ name: String) throws -> DType {
        switch name {
        case "float16": return .float16
        case "bfloat16": return .bfloat16
        case "float32": return .float32
        default: throw ProbeError("Hand-off array dtype is not an admitted floating-point type")
        }
    }

    /// Rank 0: one segment as an evaluated, owned, compact native array, the
    /// form the checked point-to-point send requires. A state snapshot is a
    /// strided view of a larger buffer and cannot be sent as it is.
    ///
    /// `corrupted` is a qualification fault: one bit of the segment is flipped
    /// after the sender's digest was computed, as a damaged transfer would.
    static func materialize(_ sender: QwenPhaseSplitHandoffSender, segment: QwenPhaseSplitSegment,
                            corrupted: Bool = false, check: () throws -> Void) throws -> MLXArray {
        var bytes = try sender.bytes(for: segment)
        if corrupted { bytes[bytes.startIndex + bytes.count / 2] ^= 0x01 }
        return try CollectivePointToPoint.materializeCompletedBytes(bytes, shape: segment.shape,
            dtype: try dtype(segment.dtype), maximumBytes: segment.byteCount, check: check)
    }
}

/// Rank 1's native side of a hand-off: each received array is read once for
/// its digest and kept. Nothing is usable until every digest has been checked.
final class QwenPhaseSplitHandoffIntake {
    let receiver: QwenPhaseSplitHandoffReceiver
    private var arrays: [MLXArray] = []

    init(receiver: QwenPhaseSplitHandoffReceiver) { self.receiver = receiver }

    var nextSegment: QwenPhaseSplitSegment? {
        receiver.segments.indices.contains(arrays.count) ? receiver.segments[arrays.count] : nil
    }

    func accept(_ array: MLXArray, check: () throws -> Void) throws {
        guard let segment = nextSegment, array.shape == segment.shape,
              array.dtype == (try QwenPhaseSplitArrays.dtype(segment.dtype)), array.nbytes == segment.byteCount else {
            throw ProbeError("Received hand-off array differs from the agreed segment")
        }
        let bytes = array.asData().data
        try check()
        try receiver.acceptSegment(arrays.count, bytes: bytes)
        arrays.append(array)
    }

    func discard() { arrays.removeAll() }

    /// The verified arrays as the state a stage adopts. Throws the receiver's
    /// refusal if any digest differed or a segment is missing.
    func adoptedState(check: () throws -> Void) throws -> QwenLayerStageAdoptedState {
        defer { arrays.removeAll() }
        _ = try receiver.finish()
        guard let header = receiver.header, arrays.count == receiver.segments.count else {
            throw ProbeError("Hand-off ended before every agreed array arrived")
        }
        var keys: [Int: MLXArray] = [:], values: [Int: MLXArray] = [:]
        var conv: [Int: MLXArray] = [:], ssm: [Int: MLXArray] = [:]
        for (index, shape) in receiver.split.shapes.enumerated() {
            guard shape.component != QwenPhaseSplitStateShape.positionOffsets else { continue }
            let parts = receiver.segments.indices.filter { receiver.segments[$0].entryIndex == index }.map { arrays[$0] }
            let array: MLXArray
            if shape.byteCount == 0 {
                array = MLXArray.zeros(shape.shape, dtype: try QwenPhaseSplitArrays.dtype(shape.dtype))
            } else if parts.count == 1 {
                array = parts[0]
            } else {
                guard parts.count > 1 else { throw ProbeError("Hand-off component has no received array") }
                // Cut along the token axis only; verify the joined tensor itself.
                array = concatenated(parts, axis: 2)
                eval(array); try check()
                guard array.shape == shape.shape, sha256(array.asData().data) == header.content.entries[index].sha256 else {
                    throw ProbeError("Reassembled hand-off tensor differs from the sender's digest")
                }
            }
            let inserted: Bool
            switch shape.component {
            case "kv.keys": inserted = keys.updateValue(array, forKey: shape.globalLayerIndex) == nil
            case "kv.values": inserted = values.updateValue(array, forKey: shape.globalLayerIndex) == nil
            case "conv": inserted = conv.updateValue(array, forKey: shape.globalLayerIndex) == nil
            case "ssm": inserted = ssm.updateValue(array, forKey: shape.globalLayerIndex) == nil
            default: throw ProbeError("Hand-off names an unknown state component")
            }
            guard inserted else { throw ProbeError("Hand-off repeats a state component") }
        }
        guard Set(keys.keys) == Set(values.keys), Set(conv.keys) == Set(ssm.keys) else {
            throw ProbeError("Hand-off state components are unpaired")
        }
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for (layer, key) in keys { attention[layer] = (keys: key, values: values[layer]!) }
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for (layer, value) in conv { recurrent[layer] = (conv: value, ssm: ssm[layer]!) }
        return .init(committedTokens: header.content.committedTokens, attention: attention, recurrent: recurrent)
    }
}
