import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// Parses real worker startup only, with no runtime, payload, device or endpoint.
final class GLMImageStartupBindingTests: XCTestCase {
    private var arguments: [String] { [
        "--model-dir", "/cpu-fixture/metadata-only", "--rank", "0", "--stage-cut", "1",
        "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        "--model-id", ClusterGLMImageCandidate.runtimeModelID,
        "--artifact-sha256", ClusterGLMImageCandidate.artifactSHA256,
        "--configuration-sha256", ClusterGLMImageCandidate.configurationSHA256,
        "--peer0-id", "cpu-0", "--peer0-build-sha256", String(repeating: "a", count: 64),
        "--peer1-id", "cpu-1", "--peer1-build-sha256", String(repeating: "b", count: 64),
        "--deadline-uptime-nanoseconds", "20000000100",
        "--runtime-profile", ClusterGLMImageCandidate.profileID, "--qualification-switches", "yes",
        "--data-plane", "encrypted_v1", "--startup-deadline-uptime-nanoseconds", "120000000100",
    ] }
    func testExplicitCandidateBindsTheActualWorkerLoadProfile() throws {
        let value = try WorkerConfiguration(arguments: arguments, now: 100)
        XCTAssertEqual(value.load.runtimeProfile, ClusterGLMImageCandidate.profileID)
        XCTAssertTrue(value.qualificationSwitchesPermitted && value.dataPlaneEncrypted)
        let text = stride(from: 0, to: arguments.count, by: 2)
            .filter { !["--runtime-profile", "--qualification-switches"].contains(arguments[$0]) }
            .flatMap { [arguments[$0], arguments[$0 + 1]] }
        XCTAssertNil(try WorkerConfiguration(arguments: text, now: 100).load.runtimeProfile)
    }
    func testCrossedSourceMissingGuardOrForeignModeRefusesBeforeLoad() throws {
        for key in ["--model-id", "--artifact-sha256", "--configuration-sha256", "--runtime-profile"] {
            var value = arguments
            value[try XCTUnwrap(value.firstIndex(of: key)) + 1] = "foreign"
            XCTAssertThrowsError(try WorkerConfiguration(arguments: value, now: 100), key)
        }
        for key in ["--qualification-switches", "--data-plane", "--startup-deadline-uptime-nanoseconds"] {
            let value = stride(from: 0, to: arguments.count, by: 2).filter { arguments[$0] != key }
                .flatMap { [arguments[$0], arguments[$0 + 1]] }
            XCTAssertThrowsError(try WorkerConfiguration(arguments: value, now: 100), key)
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments + ["--generation-mode", "phase_split_v1"], now: 100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments + ["--mtp-depth", "1"], now: 100))
    }
}
