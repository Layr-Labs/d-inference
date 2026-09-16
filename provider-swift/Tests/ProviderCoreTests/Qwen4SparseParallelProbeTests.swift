import Foundation
import MLX
import XCTest

@testable import MLXLLM

final class Qwen4SparseParallelProbeTests: XCTestCase {
    func testFullKVDefaultRemainsSeparateFromCompactOptIn() {
        XCTAssertTrue(Qwen4ExpParallelQSA.fullKVEnabled(environment: [:]))
        XCTAssertTrue(Qwen4ExpParallelQSA.fullKVEnabled(environment: [Qwen4ExpParallelQSA.flag: "1"]))
        XCTAssertFalse(Qwen4ExpParallelQSA.enabled(environment: [:]))
        XCTAssertTrue(Qwen4ExpParallelQSA.fullKVEnabled(environment: [Qwen4ExpParallelQSA.fullKVFlag: "1"]))
        for value in ["0", "true", "yes", "arbitrary"] {
            XCTAssertFalse(Qwen4ExpParallelQSA.fullKVEnabled(environment: [Qwen4ExpParallelQSA.fullKVFlag: value]))
        }
    }

    func testFullKVTwoPassMatchesOrderedSteelBits() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_QWEN4_PARALLEL_PROBE"] == "1",
              ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1" else {
            throw XCTSkip("Requires exclusive GPU lane and explicit full-KV probe")
        }
        XCTAssertTrue(Qwen4ExpNativeSparseGQA.steelEnabled())
        XCTAssertEqual(Qwen4ExpNativeSparseGQA.resolvedSteelTiles().keyTile, 64)
        XCTAssertEqual(Qwen4ExpNativeSparseGQA.resolvedSteelTiles().dimensionTile, 64)
        let initial = Qwen4ExpParallelQSAInvocation.snapshot()
        var cells = 0
        let windows = [1, 2, 4, 5, 6].flatMap { width in [false, true].map { (width, $0) } }
        for dtype in [DType.bfloat16, .float16] {
            for keyTokens in [2053, 4103, 16389] {
                for (width, capacityView) in windows {
                    MLXRandom.seed(UInt64(7117 + keyTokens + width))
                    let queries = capacityView
                        ? MLXRandom.normal([1, width, 24, 256]).asType(dtype).transposed(0, 2, 1, 3)
                        : MLXRandom.normal([1, 24, width, 256]).asType(dtype)
                    let capacity = keyTokens + (capacityView ? 16 : 0)
                    let keys = MLXRandom.normal([1, 2, capacity, 256]).asType(dtype)[0..., 0..., 0..<keyTokens, 0...]
                    let values = MLXRandom.normal([1, 2, capacity, 256]).asType(dtype)[0..., 0..., 0..<keyTokens, 0...]
                    let offset = keyTokens - width
                    var selected: [Int32] = []
                    for column in 0..<width {
                        let completeBlocks = (offset + column + 1) / 4
                        selected += (0..<512).map { Int32($0 * completeBlocks / 512) }
                    }
                    let blocks = MLXArray(selected, [1, width, 512])
                    eval(queries, keys, values, blocks)
                    let reference = try XCTUnwrap(Qwen4ExpNativeSparseGQA.attend(
                        queries: queries, keys: keys, values: values, selectedBlocks: blocks,
                        qOffset: offset, outputPartitions: 1, preserveKVStrides: false,
                        parallelScores: false, parallelFullKV: false))
                    eval(reference)
                    let referenceBits = reference.asType(.float32).asArray(Float.self).map(\.bitPattern)
                    for partitions in [1, 2, 4, 8, 16, 32] {
                        let candidate = try XCTUnwrap(Qwen4ExpNativeSparseGQA.attend(
                            queries: queries, keys: keys, values: values, selectedBlocks: blocks,
                            qOffset: offset, outputPartitions: 1, preserveKVStrides: false,
                            parallelScores: false, parallelValuePartitions: partitions,
                            parallelFullKV: true))
                        eval(candidate)
                        XCTAssertEqual(candidate.shape, reference.shape)
                        XCTAssertEqual(candidate.dtype, reference.dtype)
                        let bits = candidate.asType(.float32).asArray(Float.self).map(\.bitPattern)
                        let mismatches = zip(bits, referenceBits).filter { $0.0 != $0.1 }.count
                        print("[qwen4-parallel-full-probe] dtype=\(dtype) keys=\(keyTokens) width=\(width) capacity_view=\(capacityView) partitions=\(partitions) mismatches=\(mismatches)")
                        XCTAssertEqual(mismatches, 0, "Full-KV two-pass changed output bits")
                        cells += 1
                    }
                }
            }
        }
        XCTAssertEqual(cells, 360)
        XCTAssertEqual(Qwen4ExpParallelQSAInvocation.snapshot() - initial, cells,
                       "Do not pass by silently retaining the original kernel")
    }
}
