import DarkbloomClusterRuntime
import Darwin
import XCTest

final class ClusterQuantizedRowRoutingTests: XCTestCase {
    private let variable = ClusterQuantizedRowRouting.variable

    // Exercises apply itself, including setenv, without initializing MLX; the
    // process environment is restored after every call.
    private func check(environment: [String: String], source: String, expectedLine: String,
                       expectedValue: String, file: StaticString = #filePath, line: UInt = #line) {
        let original = getenv(variable).map { String(cString: $0) }
        defer {
            if let original { setenv(variable, original, 1) } else { unsetenv(variable) }
        }
        setenv(variable, "unchanged", 1)
        XCTAssertEqual(ClusterQuantizedRowRouting.apply(source: source, environment: environment), expectedLine,
                       file: file, line: line)
        XCTAssertEqual(getenv(variable).map { String(cString: $0) }, expectedValue, file: file, line: line)
    }

    func testTheCoreSwitchIsTheOneMLXReads() {
        XCTAssertEqual(variable, "MLX_QMV_BATCH_INVARIANT")
        XCTAssertEqual(ClusterQuantizedRowRouting.value, "1")
    }

    func testEveryClusterProcessTurnsItOnUnlessItsLauncherChose() {
        for source in ["worker", "reference", "tp-check"] {
            check(environment: [:], source: source,
                  expectedLine: "darkbloom-qmv-batch-invariant-v1 enabled=1 source=\(source)", expectedValue: "1")
            check(environment: ["MLX_METAL_FAST_SYNCH": "1"], source: source,
                  expectedLine: "darkbloom-qmv-batch-invariant-v1 enabled=1 source=\(source)", expectedValue: "1")
        }
    }

    func testALaunchersValueIsKeptAndNamed() {
        for raw in ["0", "1", ""] {
            check(environment: [variable: raw], source: "worker",
                  expectedLine: "darkbloom-qmv-batch-invariant-v1 enabled=\(raw) source=launcher",
                  expectedValue: "unchanged")
        }
    }
}
