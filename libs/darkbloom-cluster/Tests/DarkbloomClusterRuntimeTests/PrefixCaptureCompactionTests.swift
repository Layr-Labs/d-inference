import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// A captured recurrent state is kept compact: a convolution tail that views
// its whole prefill chunk is copied bit for bit into its own storage, so the
// chunk is freed, while an array that owns its storage is shared, not copied.
// Evaluates on the GPU; no model.
@Suite(.serialized) struct PrefixCaptureCompactionTests {
    @Test func compactionCopiesAViewOfALargerBufferExactlyAndFreesTheParent() throws {
        // A [1, 515, 65536] bf16 chunk (64 MiB) and its three-row tail.
        let rows = 515, width = 65_536
        var tail: MLXArray
        var compact: MLXArray
        let before: Int
        do {
            let chunk = MLXRandom.normal([1, rows, width]).asType(.bfloat16)
            eval(chunk)
            tail = chunk[0..., (rows - 3)...]
            eval(tail)
            compact = contiguous(tail)
            eval(compact)
            #expect(compact.shape == [1, 3, width] && compact.dtype == .bfloat16)
            #expect(compact.asData(access: .copy).data == tail.asData(access: .copy).data)
            Stream.gpu.synchronize()
            before = Memory.activeMemory
        }
        // Dropping the view lets the chunk go; the compact copy stays valid.
        let expected = tail.asData(access: .copy).data
        tail = MLXArray(0)
        Stream.gpu.synchronize()
        let freed = before - Memory.activeMemory
        #expect(freed >= 48 << 20, "the chunk behind the tail was not freed (\(freed) bytes)")
        #expect(compact.asData(access: .copy).data == expected)
    }

    @Test func compactionSharesAnArrayThatOwnsItsStorage() throws {
        let ssm = MLXRandom.normal([1, 48, 128, 128])
        eval(ssm)
        Stream.gpu.synchronize()
        let before = Memory.activeMemory
        let shared = contiguous(ssm)
        eval(shared)
        Stream.gpu.synchronize()
        #expect(Memory.activeMemory - before < 1 << 20, "a compact array was copied")
        #expect(shared.asData(access: .copy).data == ssm.asData(access: .copy).data)
    }
}
