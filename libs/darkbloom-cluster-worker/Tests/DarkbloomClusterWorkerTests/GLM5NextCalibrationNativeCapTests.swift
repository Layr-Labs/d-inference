import Foundation
import Darwin
import DarkbloomClusterRuntime
import MLX
import XCTest
@testable import DarkbloomClusterWorker

final class GLM5NextCalibrationNativeCapTests: XCTestCase {
    func testFreshProcessPageBackedReceiveBounds() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM_NATIVE_FOOTPRINT"] == "1" else {
            throw XCTSkip("requires a dedicated fresh worker test process")
        }
        // Metadata quotations capture this policy before the native cap exists.
        let quoted = try XCTUnwrap(Memory.allocationFootprintPolicy())
        let ceiling = 8 << 20
        try GLM5NextCalibrationNativeCap.install(bytes: ceiling)
        let previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = 0
        defer { Memory.clearCache(); Memory.cacheLimit = previousCacheLimit }
        let page = Int(getpagesize())
        for bytes in [1, 8, 255, 256, 384, page - 1, page, page + 1, page * 2 + 1] {
            try autoreleasepool {
                let payload = [UInt8](repeating: 0xa5, count: bytes)
                let array = MLXArray(payload)
                try MLX.withError {
                    eval(array)
                    Stream.cpu.synchronize()
                    Stream.gpu.synchronize()
                }
                let storage = try XCTUnwrap(array.evaluatedBufferInfo())
                let bound = try Memory.allocationFootprintUpperBound(byteCount: bytes)
                XCTAssertEqual(quoted.upperBound(byteCount: bytes), bound)
                XCTAssertTrue(storage.isUnique && storage.isRowContiguous)
                XCTAssertEqual(storage.dataOffset, 0)
                XCTAssertEqual(storage.dataElements, bytes)
                XCTAssertGreaterThanOrEqual(storage.allocatedBytes, bytes)
                XCTAssertLessThanOrEqual(storage.allocatedBytes, bound, "request bytes: \(bytes)")
                let geometry = try CollectivePointToPointShape(shape: [bytes], dtype: .uint8,
                    maximumBytes: bytes)
                XCTAssertNoThrow(try geometry.validateOwnedReceive(array), "request bytes: \(bytes)")
                XCTAssertEqual(array.asArray(UInt8.self), payload)
            }
            Memory.clearCache()
            try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling)
        }
        try autoreleasepool {
            let source = MLXArray([UInt8](repeating: 0x6b, count: 512))
            let alias = source.reshaped([1, 512])
            let offset = source[1..<385]
            try MLX.withError {
                eval(alias, offset)
                Stream.cpu.synchronize()
                Stream.gpu.synchronize()
            }
            let whole = try CollectivePointToPointShape(shape: [1, 512], dtype: .uint8, maximumBytes: 512)
            let sliced = try CollectivePointToPointShape(shape: [384], dtype: .uint8, maximumBytes: 384)
            XCTAssertThrowsError(try whole.validateOwnedReceive(alias))
            XCTAssertThrowsError(try sliced.validateOwnedReceive(offset))
            withExtendedLifetime((source, alias, offset)) {}
        }
        XCTAssertEqual(quoted.upperBound(byteCount: 0), 0)
        XCTAssertNil(quoted.upperBound(byteCount: Int.max))
        Memory.clearCache()
        try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling)
    }

    func testFreshProcessWorkerCapBinding() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM_NATIVE_CAP"] == "1" else {
            throw XCTSkip("requires a dedicated fresh worker test process")
        }
        let ceiling = 8 << 20
        XCTAssertThrowsError(try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling))
        try GLM5NextCalibrationNativeCap.install(bytes: ceiling)
        try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling)
        XCTAssertThrowsError(try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling * 2))
        XCTAssertThrowsError(try GLM5NextCalibrationNativeCap.install(bytes: ceiling * 2))
        try autoreleasepool {
            let x = MLXArray((0..<1024).map(Float.init))
            let y = x * 2 + 3
            eval(y)
            XCTAssertEqual(y.asArray(Float.self), (0..<1024).map { Float($0 * 2 + 3) })
            try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling)
        }
        Memory.clearCache()
        try GLM5NextCalibrationNativeCap.requireInstalled(bytes: ceiling)
    }
}
