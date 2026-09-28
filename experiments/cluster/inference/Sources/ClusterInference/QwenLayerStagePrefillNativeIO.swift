import Foundation
import MLX

/// Uses the existing Cmlx CPU-stream completed send/receive shim unchanged.
/// Scoped helpers return only copied CPU controls, except the explicit payload
/// receive whose owned native array belongs to the caller's release scope.
final class QwenLayerStagePrefillNativeIO {
    private let collective: Collective
    init(collective: Collective) { self.collective = collective }

    func sendBytes(_ data: Data, maximumBytes: Int, to peer: Int, check: () throws -> Void) throws {
        guard !data.isEmpty, data.count <= maximumBytes, data.count <= Int(UInt32.max) else {
            throw ProbeError("Prefill control send exceeds its local length bound")
        }
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try autoreleasepool {
                try checked()
                _ = try collective.sendCompleted(MLXArray([UInt32(data.count)]), to: peer, maximumBytes: 4, check: checked)
                _ = try collective.sendCompleted(MLXArray(Array(data)), to: peer, maximumBytes: maximumBytes, check: checked)
                try checked()
            }
        }
    }

    func receiveBytes(maximumBytes: Int, from peer: Int, check: () throws -> Void) throws -> Data {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            return try autoreleasepool {
                let lengthArray = try collective.receiveCompleted(shape: [1], dtype: .uint32, from: peer, maximumBytes: 4, check: checked)
                let length = lengthArray.item(UInt32.self)
                try checked()
                guard length > 0, Int(length) <= maximumBytes else { throw ProbeError("Prefill control receive exceeds its local length bound") }
                let array = try collective.receiveCompleted(shape: [Int(length)], dtype: .uint8,
                    from: peer, maximumBytes: maximumBytes, check: checked)
                let data = array.asData(access: .copy).data
                try checked()
                guard data.count == Int(length) else { throw ProbeError("Prefill control logical byte length differs") }
                return data
            }
        }
    }

    func sendPayload(_ array: MLXArray, maximumBytes: Int, check: () throws -> Void) throws {
        try autoreleasepool { _ = try collective.sendCompleted(array, to: 1, maximumBytes: maximumBytes, check: check) }
    }

    func receivePayload(expected: QwenLayerStageBoundaryWireExpectation, check: () throws -> Void) throws -> MLXArray {
        try collective.receiveCompleted(shape: expected.shape, dtype: nativeDType(expected.dtype),
            from: 0, maximumBytes: expected.byteCount, check: check)
    }

    func sendACK(_ values: [Int32], to peer: Int, check: () throws -> Void) throws {
        guard values.count == 64 else { throw ProbeError("Prefill ACK requires exactly 64 Int32 elements") }
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try autoreleasepool {
                _ = try collective.sendCompleted(MLXArray(values), to: peer, maximumBytes: 256, check: checked)
                try checked()
            }
        }
    }

    func receiveACK(from peer: Int, check: () throws -> Void) throws -> [Int32] {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            return try autoreleasepool {
                let array = try collective.receiveCompleted(shape: [64], dtype: .int32, from: peer, maximumBytes: 256, check: checked)
                let values = array.asArray(Int32.self)
                try checked()
                guard values.count == 64 else { throw ProbeError("Prefill received ACK has the wrong logical length") }
                return values
            }
        }
    }

    func nativeDType(_ dtype: String) throws -> DType {
        switch dtype {
        case "float16": return .float16
        case "bfloat16": return .bfloat16
        case "float32": return .float32
        default: throw ProbeError("Prefill residual dtype is not admitted")
        }
    }
}
