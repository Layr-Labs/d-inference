import MLX
import MLXLMCommon
import XCTest
@testable import DarkbloomClusterRuntime

final class CBv2PagedPrefixRestoreTests: XCTestCase {
    func testLongSlidingTailRestoresAndContinuesExactly() throws {
        let kinds = [CBv2LayerKind(attention: .slidingWindow(1024), headDim: 256,
                                  kvHeads: 1, queryHeads: 2, modelLayerIndex: 0)]
        for committed in [511, 575, 1100, 4095] {
            let backend = try PagedKVBackend(layerKinds: kinds, config: .init(
                pageSize: 16, capacityBytes: 8 << 20, dtype: .bfloat16,
                maxPrefillChunk: 512, nominalMaxSequenceLength: 8192))
            let rows = try backend.makeSequenceState(layerKinds: kinds, promptLength: committed + 1,
                                                     maxLength: committed + 16)
            let row = try XCTUnwrap(rows[0])
            let retained = min(committed, 1024), start = committed - retained
            if start > 0 { row.fastForward(to: start) }
            let keys = (MLXArray(0..<(retained * 256)).asType(.float32) / 512).reshaped([1,1,retained,256]).asType(.bfloat16)
            let values = -keys
            try CBv2PagedPrefixRestore.write(row: row, keys: keys, values: values, maximumChunkTokens: 512)
            let restored = row.snapshot()
            eval(restored.keys, restored.values)
            XCTAssertEqual(restored.offset, committed)
            XCTAssertEqual(restored.keys.asData().data, keys.asData().data)
            XCTAssertEqual(restored.values.asData().data, values.asData().data)
            let next = MLXArray.zeros([1,1,1,256], dtype: .bfloat16)
            _ = row.update(keys: next, values: next)
            let continued = row.snapshot()
            let joinedKeys = concatenated([keys, next], axis: 2)
            let joinedValues = concatenated([values, next], axis: 2)
            let dropped = max(0, retained + 1 - 1024)
            eval(continued.keys, continued.values)
            XCTAssertEqual(continued.offset, committed + 1)
            XCTAssertEqual(continued.keys.asData().data, joinedKeys[0...,0...,dropped...,0...].asData().data)
            XCTAssertEqual(continued.values.asData().data, joinedValues[0...,0...,dropped...,0...].asData().data)
            backend.release(rows)
            Stream.gpu.synchronize()
            XCTAssertEqual(backend.bytesReserved, 0)
            XCTAssertEqual(backend.bytesInUse, 0)
        }
    }

    func testInvalidRestoreRefusesBeforeChangingFrontier() throws {
        let kinds = [CBv2LayerKind(attention: .slidingWindow(1024), headDim: 256,
                                  kvHeads: 1, queryHeads: 2, modelLayerIndex: 0)]
        let backend = try PagedKVBackend(layerKinds: kinds, config: .init(
            pageSize: 16, capacityBytes: 8 << 20, dtype: .bfloat16, maxPrefillChunk: 512))
        let rows = try backend.makeSequenceState(layerKinds: kinds, promptLength: 1, maxLength: 16)
        let row = try XCTUnwrap(rows[0]), keys = MLXArray.zeros([1,1,1,256], dtype: .bfloat16)
        XCTAssertThrowsError(try CBv2PagedPrefixRestore.write(row: row, keys: keys, values: keys, maximumChunkTokens: 0))
        XCTAssertThrowsError(try CBv2PagedPrefixRestore.write(row: row, keys: keys, values: keys.squeezed(axis: 0), maximumChunkTokens: 512))
        XCTAssertEqual(row.absoluteOffset, 0)
        backend.release(rows)
        XCTAssertEqual(backend.bytesReserved, 0)
    }
}
