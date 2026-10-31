import CryptoKit
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// Provider-emitted public fixture; calls only the actual pure wire decoder.
/// No credential secret, metadata inspection, native initialization or GPU work.
final class GLM5NextCalibrationQuoteContractTests: XCTestCase {
    typealias Wire = GLM5NextCalibrationQuoteWire
    struct Fixture: Decodable {
        let document: Data
        let memberPublicKey: Data
        let peerPublicKey: Data
        let epoch: UUID
        let rank: Int
        let now: Int64
        let arguments: [String]?
        let environment: [String: String]?
        let nowUptime: UInt64?

        func decode(member: Data? = nil, peer: Data? = nil, epoch: UUID? = nil,
                    rank: Int? = nil, now: Int64? = nil, document: Data? = nil) throws -> Wire.Verified {
            try Wire.decode(document ?? self.document, memberPublicKey: member ?? memberPublicKey,
                peerPublicKey: peer ?? peerPublicKey, epoch: epoch ?? self.epoch,
                rank: rank ?? self.rank, now: now ?? self.now)
        }
    }
    func fixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        if environment["DARKBLOOM_CALIBRATION_QUOTE_FIXTURE"] == nil,
           environment["DARKBLOOM_CALIBRATION_QUOTE_REQUIRED"] != "1" {
            throw XCTSkip("Requires the current provider-emitted quote fixture")
        }
        let path = try XCTUnwrap(environment["DARKBLOOM_CALIBRATION_QUOTE_FIXTURE"],
            "Required quote contract gate must supply its provider-emitted fixture")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertLessThanOrEqual(data.count, 512 << 10)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testProviderQuoteRoundTripsThroughActualDecoder() throws {
        let f = try fixture(), result = try f.decode()
        let envelope = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: f.document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(result.request)
        XCTAssertEqual(canonical, envelope.payload, "Provider must emit the complete canonical worker quote schema")
        XCTAssertEqual(result.requestSHA256, Wire.hash(canonical))
        XCTAssertEqual(result.request.peerIdentitySHA256, Wire.hash(f.peerPublicKey))
        XCTAssertEqual(result.request.selection.mode, "coldTextBatch1")
        XCTAssertEqual(result.request.selection.rank, f.rank)
        XCTAssertEqual(result.request.selection.epoch, f.epoch)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        let selection = try XCTUnwrap(payload["selection"] as? [String: Any])
        XCTAssertNil(selection["loadCapacityBytes"])
        XCTAssertNil(selection["requestCapacityBytes"])
        XCTAssertNil(selection["workspaceEvidence"])
    }

    func testProviderLaunchArgumentsDecodeThroughActualOptions() throws {
        let f = try fixture()
        if f.arguments == nil && ProcessInfo.processInfo.environment["DARKBLOOM_CALIBRATION_QUOTE_REQUIRED"] != "1" {
            throw XCTSkip("Older optional quote fixture has no prepared launch arguments")
        }
        let arguments = try XCTUnwrap(f.arguments, "Required launch gate needs prepared arguments")
        let environment = try XCTUnwrap(f.environment)
        let now = try XCTUnwrap(f.nowUptime)
        XCTAssertEqual(arguments.first, "--glm-calibration-quote")
        let options = try GLM5NextCalibrationQuoteCommand.Options(Array(arguments.dropFirst()), now: now)
        let request = try f.decode().request
        XCTAssertEqual(options.rank, f.rank)
        XCTAssertEqual(options.epoch, f.epoch)
        func value(_ name: String) throws -> String {
            let index = try XCTUnwrap(arguments.firstIndex(of: name))
            return try XCTUnwrap(arguments.indices.contains(index + 1) ? arguments[index + 1] : nil)
        }
        XCTAssertEqual(options.request, try value("--request"))
        XCTAssertEqual(options.directory.path, try value("--model-dir"))
        XCTAssertGreaterThan(options.deadline, now)
        try Wire.requireEnvironment(environment, request: request)
        XCTAssertEqual(environment.filter { $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_") }
            .mapValues { Wire.hash(Data($0.utf8)) }, request.selection.environment.variableSHA256)
        XCTAssertEqual(environment["JACCL_RANK"], String(options.rank))
    }

    func testProviderQuoteRefusesCrossedIdentityAndExpiredLaunch() throws {
        let f = try fixture(), valid = try f.decode()
        let foreign = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertThrowsError(try f.decode(member: foreign))
        XCTAssertThrowsError(try f.decode(peer: foreign))
        XCTAssertThrowsError(try f.decode(epoch: UUID()))
        XCTAssertThrowsError(try f.decode(rank: 1 - f.rank))
        XCTAssertThrowsError(try f.decode(now: valid.request.selection.expiresUnixSeconds))
    }

    func testProviderPayloadRejectsExperimentDomainAndMutation() throws {
        let f = try fixture()
        let original = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: f.document)
        // Test-local key only: no real member or private credential is exported.
        let key = P256.Signing.PrivateKey()
        let wrongDomain = try JSONEncoder().encode(GLM5NextWorkerQualification.SignedDocument(
            payload: original.payload,
            signature: key.signature(for: GLM5NextCalibrationCommand.domain + original.payload).rawRepresentation))
        XCTAssertThrowsError(try f.decode(member: key.publicKey.x963Representation, document: wrongDomain))
        let mutated = try JSONEncoder().encode(GLM5NextWorkerQualification.SignedDocument(
            payload: original.payload + Data([32]), signature: original.signature))
        XCTAssertThrowsError(try f.decode(document: mutated))
    }
}
