import CryptoKit
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// Exact provider-emitted bytes, plus validly re-signed negative scope cases.
/// This suite never invokes run/execute, environment Metal checks, or JACCL.
final class GLM5NextProviderCalibrationContractTests: XCTestCase {
    struct Fixture {
        let document: Data
        let member: Data
        let arguments: [String]
        let entryArguments: [String]
        let environment: [String: String]
        let nowUptime: UInt64
        var configuration: WorkerConfiguration { get throws { try .init(arguments: arguments, now: nowUptime) } }
    }
    func fixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        if environment["DARKBLOOM_CALIBRATION_CONTRACT_FIXTURE"] == nil,
            environment["DARKBLOOM_CALIBRATION_CONTRACT_REQUIRED"] != "1" {
            throw XCTSkip("Cross-target gate requires the current provider-emitted calibration fixture")
        }
        let path = try XCTUnwrap(environment["DARKBLOOM_CALIBRATION_CONTRACT_FIXTURE"],
            "The required cross-target gate must supply its provider-emitted fixture")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        return try .init(document: XCTUnwrap(Data(base64Encoded: XCTUnwrap(value["document"] as? String))),
            member: XCTUnwrap(Data(base64Encoded: XCTUnwrap(value["memberPublicKey"] as? String))),
            arguments: XCTUnwrap(value["arguments"] as? [String]),
            entryArguments: XCTUnwrap(value["entryArguments"] as? [String]),
            environment: XCTUnwrap(value["environment"] as? [String: String]),
            nowUptime: XCTUnwrap(value["nowUptime"] as? UInt64))
    }
    func testExactProviderDocumentPassesActualWorkerDecoder() throws {
        let f = try fixture()
        let p = try GLM5NextCalibrationCommand.decode(f.document, memberPublicKey: f.member,
            configuration: f.configuration, now: 1000)
        XCTAssertEqual(p.selection.repository, "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp")
        XCTAssertTrue(p.selection.workspaceEvidence.isEmpty)
        XCTAssertEqual(p.authorization.promptTokenIDs, [1, 2])
        XCTAssertEqual(f.entryArguments.first, "--glm-calibrate")
        XCTAssertEqual(Array(f.entryArguments.dropFirst()), f.arguments)
        XCTAssertEqual(f.environment["JACCL_RANK"], String(p.selection.rank))
        XCTAssertEqual(f.environment.filter { $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_") }
            .mapValues { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() },
            p.selection.environment.variableSHA256)
        XCTAssertNotNil(try f.configuration.bootstrap)
        XCTAssertNotNil(try f.configuration.startupDeadlineUptimeNanoseconds)
        let signed = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: f.document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(p), signed.payload, "Worker must preserve the complete provider wire schema")
    }
    func testCrossedLaunchAndExpiryRefused() throws {
        let f = try fixture()
        for (name, value) in [("--rank", "1"), ("--membership-epoch", UUID().uuidString.lowercased()),
            ("--artifact-sha256", String(repeating: "b", count: 64)),
            ("--peer0-build-sha256", String(repeating: "b", count: 64)), ("--stage-cut", "21")] {
            var args = f.arguments; args[try XCTUnwrap(args.firstIndex(of: name)) + 1] = value
            let config = try WorkerConfiguration(arguments: args, now: f.nowUptime)
            XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(f.document, memberPublicKey: f.member,
                configuration: config, now: 1000), name)
        }
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(f.document, memberPublicKey: f.member,
            configuration: f.configuration, now: 1100))
    }
    func testServingAndUnencryptedModesRefusedBeforeNative() throws {
        let f = try fixture()
        for (name, value) in [("--keep-warm", "on"), ("--qualification-switches", "no"),
                              ("--data-plane", "plaintext")] {
            var arguments = f.arguments
            arguments[try XCTUnwrap(arguments.firstIndex(of: name)) + 1] = value
            XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments, now: f.nowUptime), name)
        }
        for extra in [["--mtp-depth", "1"], ["--evidence-directory", "/synthetic/evidence"],
                      ["--tensor-shares", "1,1"]] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: f.arguments + extra, now: f.nowUptime))
        }
    }
    func testWrongMemberDomainAndPayloadMutationRefused() throws {
        let f = try fixture(), key = P256.Signing.PrivateKey()
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(f.document,
            memberPublicKey: key.publicKey.x963Representation, configuration: f.configuration, now: 1000))
        let original = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: f.document)
        let wrongDomain = try key.signature(for: GLM5NextWorkerQualification.domain + original.payload).rawRepresentation
        let wrong = try JSONEncoder().encode(GLM5NextWorkerQualification.SignedDocument(payload: original.payload, signature: wrongDomain))
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(wrong,
            memberPublicKey: key.publicKey.x963Representation, configuration: f.configuration, now: 1000))
        let mutated = try JSONEncoder().encode(GLM5NextWorkerQualification.SignedDocument(
            payload: original.payload + Data([32]), signature: original.signature))
        XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(mutated,
            memberPublicKey: f.member, configuration: f.configuration, now: 1000))
    }
    func testSignedInvalidLimitsArtifactAndEnvironmentRefused() throws {
        let f = try fixture(), key = P256.Signing.PrivateKey()
        let original = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: f.document)
        let cases: [(String, String, Any)] = [
            ("selection", "expiresUnixSeconds", 4601), ("selection", "maximumPromptTokens", 513),
            ("selection", "maximumOutputTokens", 17), ("selection", "repository", "EigenLabs/GLM-5.3-Flash-MLX-4bit-mtp"),
            ("selection", "revision", String(repeating: "0", count: 40)),
            ("selection", "loadCapacityBytes", 4000), ("selection", "workspaceEvidence", "YQ=="),
            ("authorization", "nativeHardCapBytes", Int.max), ("authorization", "hostBudgetBytes", 0),
            ("authorization", "workspaceNativeAllowanceBytes", 2000),
            ("environment", "backend", "recording"), ("environment", "allocator", "unknown"),
            ("environment", "memoryBytes", 2000)]
        for (section, field, value) in cases {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.payload) as? [String: Any])
            if section == "environment" {
                var selection = try XCTUnwrap(json["selection"] as? [String: Any])
                var environment = try XCTUnwrap(selection["environment"] as? [String: Any])
                environment[field] = value; selection["environment"] = environment; json["selection"] = selection
            } else {
                var object = try XCTUnwrap(json[section] as? [String: Any]); object[field] = value; json[section] = object
            }
            let payload = try JSONSerialization.data(withJSONObject: json)
            let signature = try key.signature(for: GLM5NextCalibrationCommand.domain + payload).rawRepresentation
            let document = try JSONEncoder().encode(GLM5NextWorkerQualification.SignedDocument(payload: payload, signature: signature))
            XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(document,
                memberPublicKey: key.publicKey.x963Representation, configuration: f.configuration, now: 1000), "\(section).\(field)")
        }
    }
}
