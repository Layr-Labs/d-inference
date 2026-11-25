import Foundation
import MLX
@_spi(QuantizedProjectionScope) import MLXNN
import XCTest

/// Native array tests: compile/run only under the existing MLX test owner.
/// Array evaluation is deliberately outside the synchronous override body.
final class QuantizedProjectionScopeTests: XCTestCase {
    enum Expected: Error { case body, projection }
    private func layer() -> QuantizedLinear {
        QuantizedLinear(weight: MLXArray.ones([32,64], dtype: .bfloat16),
            bias: MLXArray.ones([32], dtype: .bfloat16), groupSize: 64, bits: 8)
    }
    func testBodyFailureRestoresScopeAndNestedScopeRefuses() throws {
        XCTAssertThrowsError(try QuantizedProjectionScope.withHandler({ _ in nil }) {
            try QuantizedProjectionScope.withHandler({ _ in nil }) { 1 }
        }) { XCTAssertTrue($0 is QuantizedProjectionScope.Failure) }
        XCTAssertThrowsError(try QuantizedProjectionScope.withHandler({ _ in nil }) {
            throw Expected.body
        })
        XCTAssertEqual(try QuantizedProjectionScope.withHandler({ _ in nil }) { 7 }, 7)
    }
    func testSingleRowBypassesAndBatchSeesOriginalConstantCasts() throws {
        let projection = layer()
        var calls = 0
        _ = try QuantizedProjectionScope.withHandler({ value in
            calls += 1
            XCTAssertEqual(value.scales.dtype, .float32)
            XCTAssertEqual(value.biases?.dtype, .float32)
            return nil
        }) {
            _ = projection(MLXArray.ones([1,1,64], dtype: .float32))
            XCTAssertEqual(calls, 0)
            return projection(MLXArray.ones([1,3,64], dtype: .float32))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(projection.scales.dtype, .bfloat16)
        XCTAssertEqual(projection.biases?.dtype, .bfloat16)
    }
    func testHandlerFailureCannotPublishGraphAndRestoresScope() throws {
        let projection = layer(), input = MLXArray.ones([1,3,64], dtype: .bfloat16)
        var published = false
        XCTAssertThrowsError(try {
            _ = try QuantizedProjectionScope.withHandler({ _ in throw Expected.projection }) {
                projection(input)
            }
            published = true
        }())
        XCTAssertFalse(published)
        XCTAssertEqual(try QuantizedProjectionScope.withHandler({ _ in nil }) { 9 }, 9)
    }
    func testRecursiveProjectionCannotPublishGraph() throws {
        let projection = layer(), input = MLXArray.ones([1,3,64], dtype: .bfloat16)
        XCTAssertThrowsError(try QuantizedProjectionScope.withHandler({ _ in
            _ = projection(input)
            throw Expected.projection
        }) { projection(input) }) {
            guard case QuantizedProjectionScope.Failure.recursiveProjection = $0 else {
                return XCTFail("The first recursive projection failure was overwritten")
            }
        }
    }
    func testExternalBiasIsAppliedAfterOverrideWithoutParameterMutation() throws {
        let projection = layer(), input = MLXArray.ones([1,3,64], dtype: .float32)
        let parameters = projection.parameters().flattened().map(\.0).sorted()
        try MLX.withError { fault in
            let output = try QuantizedProjectionScope.withHandler({ _ in
                MLXArray.zeros([1,3,32], dtype: .float32)
            }) { projection(input) }
            let correct = all(output .== 1)
            eval(correct); try fault.check()
            XCTAssertTrue(correct.item(Bool.self)); try fault.check()
        }
        XCTAssertEqual(projection.parameters().flattened().map(\.0).sorted(), parameters)
    }
    func testBorrowedHandlerDoesNotRetainCapturedOwner() throws {
        final class Owner {}
        weak var released: Owner?
        try autoreleasepool {
            let owner = Owner(); released = owner
            _ = try QuantizedProjectionScope.withHandler({ _ in
                withExtendedLifetime(owner) { nil }
            }) { 1 }
        }
        XCTAssertNil(released)
    }
}
