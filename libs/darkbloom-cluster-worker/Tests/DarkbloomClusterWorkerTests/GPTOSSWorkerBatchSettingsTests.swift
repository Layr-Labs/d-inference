import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import XCTest
@testable import DarkbloomClusterWorker

final class GPTOSSWorkerBatchSettingsTests: XCTestCase {
    func testWorkerUsesActualRuntimeEffectiveWidthAndRefusesConcurrentRecordingBeforeLoad() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        for mode in ClusterGenerationMode.allCases {
            for lanes in 1...8 {
                let environment = [key: String(lanes)]
                let expected = mode == .pipeline ? lanes : 1
                XCTAssertEqual(try GPTOSSBatchSettings.fromEnvironment(environment, mode: mode).lanes, expected)
                XCTAssertEqual(try GPTOSSWorkerRuntime.batchLaunchLanes(environment: environment,
                    mode: mode, recording: false), expected)
                if expected == 1 {
                    XCTAssertEqual(try GPTOSSWorkerRuntime.batchLaunchLanes(environment: environment,
                        mode: mode, recording: true), 1)
                } else {
                    XCTAssertThrowsError(try GPTOSSWorkerRuntime.batchLaunchLanes(environment: environment,
                        mode: mode, recording: true))
                }
            }
        }
        for invalid in ["0", "9", "unbounded", "999999999999999999999999"] {
            XCTAssertThrowsError(try GPTOSSWorkerRuntime.batchLaunchLanes(environment: [key: invalid],
                mode: .pipeline, recording: false))
        }
        XCTAssertEqual(try GPTOSSWorkerRuntime.batchLaunchLanes(environment: [:], mode: .pipeline, recording: false), 1)
    }
}
