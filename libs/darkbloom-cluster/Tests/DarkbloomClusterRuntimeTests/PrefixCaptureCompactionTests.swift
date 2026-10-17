import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// A captured recurrent state is kept compact (`QwenLayerStageSession.capturePrefix`
// applies `contiguous`): a convolution tail that views its whole prefill chunk
// is copied bit for bit into its own storage, so holding it no longer holds
// the chunk, while an array that owns its storage is shared, not copied.
// Checked by storage address (no process-wide memory counters, which other
// tests running in parallel would disturb). Evaluates on the GPU; no model.
struct PrefixCaptureCompactionTests {
    private func address(_ array: MLXArray) -> UInt {
        array.asData(access: .noCopy).data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
    }

    @Test func aTailViewOfItsChunkIsCopiedExactlyIntoItsOwnStorage() {
        // [1, 515, 512] bf16: the shape of a 512-token chunk's convolution input with its 3-row carry.
        let rows = 515, width = 512
        let chunk = MLXRandom.normal([1, rows, width]).asType(.bfloat16)
        eval(chunk)
        let tail = chunk[0..., (rows - 3)...]
        eval(tail)
        let base = address(chunk), end = base + UInt(chunk.nbytes)
        // The tail is a view: its storage lies inside the chunk's.
        #expect(address(tail) == base + UInt((rows - 3) * width * 2))
        let compact = contiguous(tail)
        eval(compact)
        #expect(compact.shape == [1, 3, width] && compact.dtype == .bfloat16)
        #expect(!(base ..< end).contains(address(compact)), "the compact tail still points into its chunk")
        #expect(compact.asData(access: .copy).data == tail.asData(access: .copy).data)
    }

    @Test func anArrayThatOwnsItsStorageIsSharedNotCopied() {
        let ssm = MLXRandom.normal([1, 16, 64, 64])
        eval(ssm)
        let shared = contiguous(ssm)
        eval(shared)
        #expect(address(shared) == address(ssm))
        #expect(shared.asData(access: .copy).data == ssm.asData(access: .copy).data)
    }
}
