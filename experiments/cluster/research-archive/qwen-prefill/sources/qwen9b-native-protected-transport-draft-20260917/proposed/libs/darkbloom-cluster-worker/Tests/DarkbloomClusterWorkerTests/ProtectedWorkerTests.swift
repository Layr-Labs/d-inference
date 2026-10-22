import Foundation
import XCTest
@testable import DarkbloomClusterWorker

final class ProtectedWorkerTests: XCTestCase {
    private var ordinary: [String] {
        ["--model-dir", "/fixture/no-payload", "--rank", "0", "--stage-cut", "16",
         "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_9b",
         "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
         "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
         "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "c", count: 64),
         "--deadline-uptime-nanoseconds", "300000000100"]
    }
    private var bootstrap: [String] {
        ["--bootstrap-socket-path", "/private/tmp/fixture/bootstrap.sock", "--bootstrap-owner-pid", "123",
         "--bootstrap-deadline-uptime-nanoseconds", "1000000"]
    }
    // Argument parsing is separate from the actual typed Start/socket checks.
    private var protection: [String] {
        ["--protected-record-profile", "qwen9b_short_records_experiment_v1",
         "--native-authorization-start-base64", Data([1, 2, 3]).base64EncodedString()]
    }
    func testOrdinaryArgumentsKeepTheirOriginalScope() throws {
        for cut in [4, 8, 12, 16] {
            var args = ordinary; args[5] = String(cut)
            let value = try WorkerConfiguration(arguments: args, now: 100)
            XCTAssertNil(value.protection); XCTAssertNil(value.bootstrap)
            XCTAssertEqual(value.load.stageCut, cut)
        }
        XCTAssertNil(try WorkerConfiguration(arguments: ordinary + bootstrap, now: 100).protection)
    }
    func testExplicitCompleteProtectedSelectionParsesWithoutOpeningSocket() throws {
        let value = try WorkerConfiguration(arguments: ordinary + bootstrap + protection, now: 100)
        XCTAssertNotNil(value.bootstrap)
        XCTAssertEqual(value.protection?.start, Data([1, 2, 3]))
        XCTAssertEqual(value.protection?.profile, "qwen9b_short_records_experiment_v1")
    }
    func testMissingProfileStartOrBootstrapRefusesWithoutFallback() throws {
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + protection, now: 100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + bootstrap + Array(protection.prefix(2)), now: 100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + bootstrap + Array(protection.suffix(2)), now: 100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + Array(bootstrap.dropLast(2)) + protection, now: 100))
    }
    func testUnknownProfileDuplicateAndNoncanonicalPublicStartRefuse() throws {
        var wrong = protection; wrong[1] = "serving"
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + bootstrap + wrong, now: 100))
        for encoded in ["", "%%%", "AQID\n", String(repeating: "A", count: 4097)] {
            var changed = protection; changed[3] = encoded
            XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + bootstrap + changed, now: 100))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + bootstrap + protection + protection, now: 100))
    }
    func testDifferentCutAndLookaheadRefuseThisFirstExperiment() throws {
        for cut in [4, 8, 12] {
            var args = ordinary; args[5] = String(cut)
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args + bootstrap + protection, now: 100))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: ordinary + bootstrap + protection
            + ["--prefill-schedule", "one_chunk_lookahead_v1"], now: 100))
    }
    func testMetadataCommandSelectsExplicitDescriptionOnly() throws {
        for (command, expected) in [("--describe-runtime", false), ("--describe-protected-runtime", true)] {
            let value = try WorkerCapabilityCommand.Arguments([command, "--config", "/fixture/config.json",
                "--manifest", "/fixture/manifest.json", "--expected-executable-sha256", String(repeating: "a", count: 64)])
            XCTAssertEqual(value.protectedDescription, expected)
        }
        XCTAssertThrowsError(try WorkerCapabilityCommand.Arguments(["--describe-protected-runtime"]))
    }
}
