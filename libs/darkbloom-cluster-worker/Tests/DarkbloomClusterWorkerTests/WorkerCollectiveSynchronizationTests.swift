import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Darwin
import XCTest
@testable import DarkbloomClusterWorker

final class WorkerCollectiveSynchronizationTests: XCTestCase {
    private let qwen27 = "registered_qwen38_27b"
    private let lanes = QwenBatchSettings.lanesEnvironmentName
    private let variable = WorkerCollectiveSynchronization.variable

    // These checks exercise apply itself, including setenv, without initializing MLX.
    // Every invocation restores the process environment, including on a thrown error.
    private func check(model: String, mode: ClusterGenerationMode = .tensorParallel,
                       environment: [String: String], expected: String?, source: String = "worker",
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let original = getenv(variable).map { String(cString: $0) }
        defer {
            if let original { setenv(variable, original, 1) } else { unsetenv(variable) }
        }
        setenv(variable, "unchanged", 1)
        let result = try WorkerCollectiveSynchronization.apply(mode: mode, modelID: model,
                                                               environment: environment)
        let expectedLine = expected.map { "darkbloom-collective-sync-v1 fast_synch=\($0) source=\(source)" }
        XCTAssertEqual(result, expectedLine, "\(model) \(mode) \(environment)", file: file, line: line)
        let expectedEnvironment = expected != nil && source == "worker" ? expected! : "unchanged"
        XCTAssertEqual(getenv(variable).map { String(cString: $0) }, expectedEnvironment, file: file, line: line)
    }

    func testBatchedQwen27KeepsFastSynchronization() throws {
        for raw in ["2", "3", "4", "5", "6", "7", "8", " 2 ", "+2", "02"] {
            try check(model: qwen27, environment: [lanes: raw], expected: "1")
        }
        for environment in [[:], [lanes: "1"], [lanes: ""], [lanes: " \n"]] {
            try check(model: qwen27, environment: environment, expected: "1")
        }
    }

    func testOtherCatalogModelsKeepFastSynchronization() throws {
        let models = ClusterResidentModelCatalog.all.map(\.runtimeModelID).filter { $0 != qwen27 }
        XCTAssertTrue(models.contains { $0.contains("glm") })
        XCTAssertTrue(models.contains("registered_qwen35_9b"))
        for model in models {
            for raw in ["1", "2", "8", "invalid"] {
                try check(model: model, environment: [lanes: raw], expected: "1")
            }
        }
    }

    func testLauncherPrecedenceIsUnchanged() throws {
        for raw in ["0", "1", "legacy-direct-launch-value"] {
            for capacity in ["1", "2", "8", "invalid"] {
                try check(model: qwen27, environment: [lanes: capacity, variable: raw],
                          expected: raw, source: "launcher")
            }
        }
    }

    func testNonTensorModesLeaveTheEnvironmentAlone() throws {
        for mode in ClusterGenerationMode.allCases where mode != .tensorParallel {
            for environment in [[lanes: "8"], [lanes: "invalid"], [lanes: "2", variable: "0"]] {
                try check(model: qwen27, mode: mode, environment: environment, expected: nil)
            }
        }
    }

    func testInvalidQwen27CapacityRefusesBeforeChangingTheSetting() throws {
        let original = getenv(variable).map { String(cString: $0) }
        defer {
            if let original { setenv(variable, original, 1) } else { unsetenv(variable) }
        }
        for raw in ["0", "9", "-1", "two", "2.0", "9999999999999999999999999"] {
            setenv(variable, "unchanged", 1)
            XCTAssertThrowsError(try WorkerCollectiveSynchronization.apply(mode: .tensorParallel,
                modelID: qwen27, environment: [lanes: raw]))
            XCTAssertEqual(getenv(variable).map { String(cString: $0) }, "unchanged")
        }
    }
}
