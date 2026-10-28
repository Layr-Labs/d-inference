import Cmlx
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import DarkbloomClusterRuntime

/// Model-free tests of the real recurrent transaction and real MLX operations.
/// CPU is the default. A separate explicit, owned GPU grant must set
/// DARKBLOOM_COMPACTION_TEST_DEVICE=gpu; unknown values fail rather than skip.
final class ConvolutionCompactionTests: XCTestCase {
    private enum Marker: Error { case stop }

    private func onDevice(_ body: () throws -> Void) throws {
        let value = ProcessInfo.processInfo.environment["DARKBLOOM_COMPACTION_TEST_DEVICE"] ?? "cpu"
        guard value == "cpu" || value == "gpu" else { throw Marker.stop }
        try Device.withDefaultDevice(value == "cpu" ? .cpu : .gpu) {
            try MLX.withError { nativeError in
                do { try body(); try nativeError.check() }
                catch { try nativeError.check(); throw error }
            }
        }
    }

    private func rows(_ rank: Int = 0) throws -> QwenConvolutionCompactionRows {
        try .init(rank: rank, bound: Memory.allocationFootprintUpperBound(byteCount:))
    }

    private func descriptor(_ array: MLXArray) throws -> UInt {
        var identity: UInt = 0, allowed = false
        guard _mlx_array_constant_cache_identity(&identity, &allowed, array.ctx) == 0,
              identity != 0 else { throw Marker.stop }
        return identity
    }

    private func stage(_ evaluation: CBv2RecurrentStateEvaluation, spec: CBv2RecurrentStateSpec,
                       chunk: Int = 16, value: Float = 0,
                       convOverride: ((Int, MLXArray) -> MLXArray)? = nil) throws {
        for (position, layer) in spec.layers.enumerated() {
            let parent = MLXArray.full([1, chunk + 3, 10240], values: MLXArray(value), dtype: .bfloat16)
            let tail = parent[0..., chunk...][0..<1]
            try evaluation.stage(modelLayerIndex: layer.modelLayerIndex,
                conv: convOverride?(position, tail) ?? tail,
                ssm: MLXArray.zeros(layer.ssmShape, dtype: .float32))
        }
    }

    private func committedOwner(_ compact: QwenConvolutionCompactionRows) throws -> CBv2RecurrentRequestState {
        let owner = try CBv2RecurrentRequestState(spec: compact.spec)
        let evaluation = try owner.bind()
        try stage(evaluation, spec: compact.spec, value: 1)
        let roots = try evaluation.evaluate()
        try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {})
        eval(roots)
        try compact.requireEvaluated(owner)
        try evaluation.commit()
        return owner
    }

    func testNamedAllowanceUsesOnlyExistingConvolutionTerm() throws {
        func bound(_ bytes: Int) -> Int {
            let rounded = (bytes + 16383) / 16384 * 16384
            return rounded + min(rounded - 1, 32767)
        }
        let first = try QwenConvolutionCompactionRows(rank: 0, bound: bound)
        let last = try QwenConvolutionCompactionRows(rank: 1, bound: bound)
        XCTAssertEqual(first.spec.layers.count, 12)
        XCTAssertEqual(last.spec.layers.count, 36)
        XCTAssertEqual(first.compactAllocationBound, 98303)
        XCTAssertEqual(first.compactThreeGenerationBytes, 3_538_908)
        XCTAssertEqual(last.compactThreeGenerationBytes, 10_616_724)
        XCTAssertEqual(first.namedConvolutionBytes, 23_592_816)
        XCTAssertEqual(last.namedConvolutionBytes, first.namedConvolutionBytes)
        XCTAssertLessThanOrEqual(last.compactThreeGenerationBytes, last.namedConvolutionBytes)
    }

    func testInvalidOrInsufficientAllocatorProofRefuses() throws {
        XCTAssertThrowsError(try QwenConvolutionCompactionRows(rank: -1, bound: { $0 }))
        XCTAssertThrowsError(try QwenConvolutionCompactionRows(rank: 2, bound: { $0 }))
        XCTAssertThrowsError(try QwenConvolutionCompactionRows(rank: 0, bound: { $0 - 1 }))
        XCTAssertThrowsError(try QwenConvolutionCompactionRows(rank: 0, bound: { _ in Int.max }))
        XCTAssertThrowsError(try QwenConvolutionCompactionRows(rank: 1,
            bound: { $0 == 61440 ? 1_000_000 : $0 }))
    }

    func testActualLargeTailBitsAndCopyAliasControl() throws {
        try onDevice {
            // Includes signed zero, subnormal, finite extremes and NaN payloads.
            let pattern: [UInt16] = [0, 0x8000, 1, 0x3f80, 0xbf80, 0x7f7f, 0x0080, 0x7fc1]
            for chunk in [256, 512] {
                let count = (chunk + 3) * 10240
                let words = (0..<count).map { pattern[$0 % pattern.count] }
                let parent = MLXArray(words).view(dtype: .bfloat16).reshaped([1, chunk + 3, 10240])
                let tail = parent[0..., chunk...][0..<1]
                var copiedContext = mlx_array_new()
                guard mlx_copy(&copiedContext, tail.ctx, StreamOrDevice.default.ctx) == 0 else { throw Marker.stop }
                let alias = MLXArray(copiedContext), compact = tail.contiguous()
                eval([parent, tail, alias, compact])
                let original = try XCTUnwrap(parent.evaluatedBufferInfo())
                let aliased = try XCTUnwrap(alias.evaluatedBufferInfo())
                let result = try XCTUnwrap(compact.evaluatedBufferInfo())
                XCTAssertEqual(aliased.allocatedBytes, original.allocatedBytes)
                XCTAssertEqual(aliased.dataOffset, try XCTUnwrap(tail.evaluatedBufferInfo()).dataOffset)
                XCTAssertGreaterThan(original.allocatedBytes, 3 * 10240 * 2 + 16384)
                XCTAssertEqual(result.dataOffset, 0)
                XCTAssertEqual(result.dataElements, 3 * 10240)
                XCTAssertLessThanOrEqual(result.allocatedBytes,
                    try Memory.allocationFootprintUpperBound(byteCount: 3 * 10240 * 2))
                XCTAssertEqual(compact.shape, tail.shape)
                XCTAssertEqual(compact.dtype, tail.dtype)
                XCTAssertEqual(compact.view(dtype: .uint16).asArray(UInt16.self), Array(words.suffix(3 * 10240)))
                XCTAssertEqual(parent.view(dtype: .uint16).asArray(UInt16.self), words)
            }
        }
    }

    func testTwoActualPlainCommitsPreserveOldStateAndUseOneEval() throws {
        try onDevice {
            let compact = try rows(), owner = try committedOwner(compact)
            defer { try? owner.release() }
            let old = try XCTUnwrap(owner.confirmedStateSnapshot())
            let oldIDs = try compact.spec.layers.map { try descriptor(old[$0.modelLayerIndex]!.conv!) }
            let evaluation = try owner.bind()
            try stage(evaluation, spec: compact.spec, chunk: 256)
            let roots = try evaluation.evaluate(), before = EvalProbe.evalsCompleted
            try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {})
            XCTAssertEqual(EvalProbe.evalsCompleted, before)
            XCTAssertEqual(try compact.spec.layers.map { try descriptor(old[$0.modelLayerIndex]!.conv!) }, oldIDs)
            eval(roots)
            try compact.requireEvaluated(owner)
            XCTAssertEqual(EvalProbe.evalsCompleted, before + 1)
            for layer in compact.spec.layers {
                XCTAssertTrue(old[layer.modelLayerIndex]!.conv!.asArray(Float.self).allSatisfy { $0 == 1 })
            }
            try evaluation.commit()
            for layer in compact.spec.layers {
                XCTAssertFalse(owner.confirmedStateSnapshot()![layer.modelLayerIndex]!.conv === old[layer.modelLayerIndex]!.conv)
                XCTAssertTrue(owner.confirmedStateSnapshot()![layer.modelLayerIndex]!.conv!.asArray(Float.self).allSatisfy { $0 == 0 })
            }
        }
    }

    func testCommittedAliasRefusesBeforeAnyMutation() throws {
        try onDevice {
            let compact = try rows(), owner = try committedOwner(compact)
            defer { try? owner.release() }
            let old = owner.confirmedStateSnapshot()!, index = compact.spec.modelLayerIndices.last!
            let evaluation = try owner.bind()
            try stage(evaluation, spec: compact.spec, convOverride: { position, tail in
                position == compact.spec.layers.count - 1 ? old[index]!.conv! : tail
            })
            let roots = try evaluation.evaluate(), before = try roots.map(descriptor)
            XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {}))
            XCTAssertEqual(try roots.map(descriptor), before)
            try evaluation.rollback()
            XCTAssertTrue(owner.confirmedStateSnapshot()![index]!.conv === old[index]!.conv)
        }
    }

    func testCrossLayerPendingAliasRefusesBeforeAnyMutation() throws {
        try onDevice {
            let compact = try rows(), owner = try CBv2RecurrentRequestState(spec: compact.spec)
            defer { try? owner.release() }
            let shared = MLXArray.zeros([1, 3, 10240], dtype: .bfloat16)
            let evaluation = try owner.bind()
            try stage(evaluation, spec: compact.spec, convOverride: { _, _ in shared })
            let roots = try evaluation.evaluate(), before = try roots.map(descriptor)
            XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {}))
            XCTAssertEqual(try roots.map(descriptor), before)
            try evaluation.rollback()
            XCTAssertNil(owner.confirmedStateSnapshot())
        }
    }

    func testWrongShapeDTypeAndRootOrderRefuseBeforeMutation() throws {
        try onDevice {
            for variant in 0..<4 {
                let compact = try rows(), owner = try CBv2RecurrentRequestState(spec: compact.spec)
                let evaluation = try owner.bind()
                try stage(evaluation, spec: compact.spec, convOverride: { position, tail in
                    guard position == compact.spec.layers.count - 1 else { return tail }
                    if variant == 0 { return MLXArray.zeros([1, 2, 10240], dtype: .bfloat16) }
                    if variant == 1 { return tail.asType(.float32) }
                    return tail
                })
                var roots = try evaluation.evaluate()
                if variant == 2 { roots.swapAt(0, 1) }
                if variant == 3 { roots.removeLast() }
                let before = try roots.map(descriptor)
                XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {}))
                XCTAssertEqual(try roots.map(descriptor), before)
                try evaluation.rollback(); try owner.release()
            }
        }
    }

    func testOtherRankStateGeometryRefusesWithoutMutation() throws {
        try onDevice {
            let first = try rows(0), last = try rows(1)
            let owner = try CBv2RecurrentRequestState(spec: first.spec)
            let evaluation = try owner.bind(); try stage(evaluation, spec: first.spec)
            let roots = try evaluation.evaluate(), before = try roots.map(descriptor)
            XCTAssertThrowsError(try last.stage(owner: owner, evaluation: evaluation, roots: roots, check: {}))
            XCTAssertEqual(try roots.map(descriptor), before)
            try evaluation.rollback(); try owner.release()
        }
    }

    func testCapturedWindowAndUncommittedSuccessorRefuse() throws {
        try onDevice {
            let compact = try rows(), owner = try CBv2RecurrentRequestState(spec: compact.spec)
            let captured = try owner.bind()
            for layer in compact.spec.layers {
                try captured.stageCaptured(modelLayerIndex: layer.modelLayerIndex,
                    conv: MLXArray.zeros([2] + layer.convShape, dtype: .bfloat16),
                    ssm: MLXArray.zeros([2] + layer.ssmShape, dtype: .float32), positions: 2)
            }
            let capturedRoots = try captured.evaluate()
            XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: captured, roots: capturedRoots, check: {}))
            try captured.rollback()
            let first = try owner.bind(); try stage(first, spec: compact.spec); _ = try first.evaluate()
            let second = try owner.bind(); try stage(second, spec: compact.spec)
            let roots = try second.evaluate()
            XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: second, roots: roots, check: {}))
            try second.rollback(); try first.rollback(); try owner.release()
        }
    }

    func testCheckFailureAfterCopyConstructionDoesNotMutate() throws {
        try onDevice {
            let compact = try rows(), owner = try CBv2RecurrentRequestState(spec: compact.spec)
            let evaluation = try owner.bind(); try stage(evaluation, spec: compact.spec)
            let roots = try evaluation.evaluate(), before = try roots.map(descriptor)
            var checks = 0
            XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {
                checks += 1; if checks == 2 { throw Marker.stop }
            }))
            XCTAssertEqual(checks, 2)
            XCTAssertEqual(try roots.map(descriptor), before)
            try evaluation.rollback(); try owner.release()
        }
    }

    func testPostMutationFailureOnlyChangesPendingAndRollsBack() throws {
        try onDevice {
            let compact = try rows(), owner = try committedOwner(compact)
            let old = owner.confirmedStateSnapshot()!, firstIndex = compact.spec.modelLayerIndices[0]
            let oldDescriptor = try descriptor(old[firstIndex]!.conv!)
            let evaluation = try owner.bind(); try stage(evaluation, spec: compact.spec)
            let roots = try evaluation.evaluate(), pendingBefore = try descriptor(roots[0])
            var checks = 0
            XCTAssertThrowsError(try compact.stage(owner: owner, evaluation: evaluation, roots: roots, check: {
                checks += 1; if checks == 3 { throw Marker.stop }
            }))
            XCTAssertEqual(checks, 3)
            XCTAssertNotEqual(try descriptor(roots[0]), pendingBefore)
            XCTAssertEqual(try descriptor(owner.confirmedStateSnapshot()![firstIndex]!.conv!), oldDescriptor)
            try evaluation.rollback()
            XCTAssertTrue(owner.confirmedStateSnapshot()![firstIndex]!.conv === old[firstIndex]!.conv)
            try owner.release()
        }
    }
}
