import Cmlx
import MLX
import XCTest

/// Calls the linked native C bridge, with no backend, Metal, model or network initialization.
final class NativeStartupWaitBridgeTests: XCTestCase {
    func testBeginRefusesAnUninitializedGroupThroughTheActualErrorBridge() throws {
        let group = mlx_distributed_group_new()
        defer { _ = mlx_distributed_group_free(group) }
        XCTAssertNil(group.ctx)
        XCTAssertThrowsError(try MLX.withError { error in
            let status = mlx_distributed_group_begin_startup_wait_budget(group, 1)
            XCTAssertNotEqual(status, 0)
            try error.check()
        })
    }

    func testEndRefusesAnUninitializedGroupThroughTheActualErrorBridge() throws {
        let group = mlx_distributed_group_new()
        defer { _ = mlx_distributed_group_free(group) }
        XCTAssertNil(group.ctx)
        XCTAssertThrowsError(try MLX.withError { error in
            let status = mlx_distributed_group_end_startup_wait_budget(group)
            XCTAssertNotEqual(status, 0)
            try error.check()
        })
    }
}
