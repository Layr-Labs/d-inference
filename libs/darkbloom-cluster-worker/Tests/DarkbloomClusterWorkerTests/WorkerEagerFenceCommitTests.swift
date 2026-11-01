import DarkbloomClusterProtocol
import Darwin
import XCTest
@testable import DarkbloomClusterWorker

final class WorkerEagerFenceCommitTests: XCTestCase {
    func testReporterOnlyDescribesExplicitCanonicalTensorChoices() {
        let key = WorkerEagerFenceCommit.variable
        let original = getenv(key).map { String(cString: $0) }
        for mode in ClusterGenerationMode.allCases {
            XCTAssertNil(WorkerEagerFenceCommit.report(mode: mode, environment: [:]))
            for value in ["0", "1", "", "true", "false", "2", "-1", "00", "01", " 0", "0\n"] {
                let expected = mode == .tensorParallel && ["0", "1"].contains(value)
                    ? "darkbloom-eager-fence-commit-v1 enabled=\(value) source=launcher" : nil
                XCTAssertEqual(WorkerEagerFenceCommit.report(mode: mode, environment: [key: value]), expected)
                XCTAssertEqual(getenv(key).map { String(cString: $0) }, original,
                    "Diagnostic reporting changed the native environment")
            }
        }
    }
}
