import CryptoKit
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// Pure wire/option checks: never calls quote/run, MLX or device APIs.
final class GLM5NextCalibrationQuoteTests: XCTestCase {
    typealias Wire = GLM5NextCalibrationQuoteWire
    struct Fixture {
        let member = P256.Signing.PrivateKey(), peer = P256.Signing.PrivateKey()
        let epoch = UUID()
        var object: [String: Any] {
            let hash = String(repeating: "a", count: 64)
            let peerHash = Wire.hash(peer.publicKey.x963Representation)
            return ["quoteRequestID": UUID().uuidString, "peerIdentitySHA256": peerHash, "appSHA256": hash,
                "selection": ["version": 1, "epoch": epoch.uuidString, "rank": 0, "expiresUnixSeconds": 1200,
                    "repository": "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp",
                    "revision": "8841c52a1e8400bd7d3e7e631c916a6c4e6757b0",
                    "artifactSHA256": "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac",
                    "files": ["config.json": ["bytes": 10023646, "sha256": "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b"],
                        "model.safetensors.index.json": ["bytes": 12351468, "sha256": "b6cdec53a012ec4a8b383d37224f5955d463ec244d80b43d24fac72aa4c07b47"],
                        "model-00001.safetensors": ["bytes": 100, "sha256": hash]],
                    "cut": 22, "profileID": "synthetic", "maximumPromptTokens": 4, "maximumChunkTokens": 2,
                    "maximumOutputTokens": 2, "maximumContextTokens": 8, "policy": "serving_v1",
                    "storage": "nvfp4Hybrid", "mode": "coldTextBatch1", "hostAllocationQuantum": 16, "hostAllocationOverhead": 0,
                    "environment": ["binarySHA256": hash, "metallibSHA256": hash, "backend": "jaccl",
                        "allocator": "disableFreedBufferCache", "os": "synthetic", "deviceRegistryID": 1,
                        "deviceName": "synthetic", "architecture": "synthetic", "maximumBufferBytes": 4096,
                        "recommendedWorkingSetBytes": 4096, "memoryBytes": 10000,
                        "variableSHA256": ["DARKBLOOM_GLM_CALIBRATION_APP_SHA256": Wire.hash(Data(hash.utf8)),
                            "DARKBLOOM_GLM_CALIBRATION_PEER_SHA256": Wire.hash(Data(peerHash.utf8))]]],
                "authorization": ["requestID": UUID().uuidString, "nativeHardCapBytes": 2000, "hostBudgetBytes": 1000,
                    "osHeadroomBytes": 1000, "workspaceNativeAllowanceBytes": 100, "workspaceHostAllowanceBytes": 100,
                    "promptTokenIDs": [1, 2], "outputCount": 2, "chunkSize": 2]]
        }
        func signed(_ object: [String: Any], domain: Data = Wire.domain) throws -> Data {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try JSONEncoder().encode(GLM5NextWorkerQualification.SignedDocument(payload: bytes,
                signature: member.signature(for: domain + bytes).rawRepresentation))
        }
        func decode(_ bytes: Data, memberKey: Data? = nil, peerKey: Data? = nil,
                    rank: Int = 0, now: Int64 = 1000) throws -> Wire.Verified {
            try Wire.decode(bytes, memberPublicKey: memberKey ?? member.publicKey.x963Representation,
                peerPublicKey: peerKey ?? peer.publicKey.x963Representation, epoch: epoch, rank: rank, now: now)
        }
    }
    func testValidRequestCanonicalDigestAndNoFinalCapacityFields() throws {
        let f = Fixture(), bytes = try f.signed(f.object)
        let result = try f.decode(bytes)
        XCTAssertEqual(result.request.selection.mode, "coldTextBatch1")
        XCTAssertEqual(result.requestSHA256, try GLM5NextWorkerQualification.hash(result.request))
        let encoded = try JSONEncoder().encode(result.request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let selection = try XCTUnwrap(object["selection"] as? [String: Any])
        XCTAssertNil(selection["loadCapacityBytes"]); XCTAssertNil(selection["requestCapacityBytes"])
        XCTAssertNil(selection["workspaceEvidence"])
    }
    func testWrongDomainMemberPeerRankAndExpiryRefused() throws {
        let f = Fixture(), bytes = try f.signed(f.object), foreign = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertThrowsError(try f.decode(bytes, memberKey: foreign))
        XCTAssertThrowsError(try f.decode(bytes, peerKey: foreign))
        XCTAssertThrowsError(try f.decode(bytes, rank: 1))
        XCTAssertThrowsError(try f.decode(bytes, now: 1200))
        XCTAssertThrowsError(try f.decode(bytes, now: -1))
        XCTAssertThrowsError(try f.decode(f.signed(f.object, domain: GLM5NextCalibrationCommand.domain)))
        XCTAssertThrowsError(try f.decode(Data(repeating: 0, count: (256 << 10) + 1)))
    }
    func testSignedInvalidModesCapacityAndUnknownFieldsRefusedBeforeMetadata() throws {
        let f = Fixture()
        let cases: [(String, String, Any)] = [
            ("selection", "mode", "vision"), ("selection", "mode", "mtp"), ("selection", "mode", "batch2"),
            ("selection", "cut", 45), ("selection", "epoch", UUID().uuidString),
            ("selection", "expiresUnixSeconds", 4601), ("selection", "maximumPromptTokens", 2049),
            ("selection", "maximumOutputTokens", 17), ("selection", "hostAllocationQuantum", 0),
            ("selection", "loadCapacityBytes", 3000), ("selection", "workspaceEvidence", ""),
            ("selection", "repository", "wrong"), ("authorization", "nativeHardCapBytes", Int.max),
            ("authorization", "hostBudgetBytes", 0), ("authorization", "osHeadroomBytes", 7000),
            ("authorization", "workspaceHostAllowanceBytes", 1000), ("authorization", "promptTokenIDs", [-1])]
        for (section, field, value) in cases {
            var object = f.object, nested = try XCTUnwrap(object[section] as? [String: Any])
            nested[field] = value; object[section] = nested
            XCTAssertThrowsError(try f.decode(f.signed(object)), "\(section).\(field)")
        }
        var object = f.object; object["peerIdentitySHA256"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try f.decode(f.signed(object)))
        object = f.object; object["appSHA256"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try f.decode(f.signed(object)))
    }
    func testEnvironmentRefusesUnsignedInjectionBeforeDeviceQueries() throws {
        let f = Fixture(), verified = try f.decode(f.signed(f.object))
        let r = verified.request
        let environment = ["JACCL_RANK": "0", "DARKBLOOM_GLM_CALIBRATION_APP_SHA256": r.appSHA256,
            "DARKBLOOM_GLM_CALIBRATION_PEER_SHA256": r.peerIdentitySHA256]
        try Wire.requireEnvironment(environment, request: r)
        // Foundation adds this key in the launched child even when its parent
        // supplies an explicit environment; it is outside model authority.
        var platformEnvironment = environment
        platformEnvironment["__CF_USER_TEXT_ENCODING"] = "0x1F5:0x0:0x0"
        XCTAssertNoThrow(try Wire.requireEnvironment(platformEnvironment, request: r))
        for (key, value) in [("DYLD_INSERT_LIBRARIES", "/wrong"), ("MLX_UNBOUND", "1"),
            ("__CF_UNAUTHORIZED", "1"), ("JACCL_RANK", "1"),
            ("DARKBLOOM_GLM_CALIBRATION_APP_SHA256", String(repeating: "b", count: 64))] {
            var changed = platformEnvironment; changed[key] = value
            XCTAssertThrowsError(try Wire.requireEnvironment(changed, request: r))
        }
    }

    func testOptionsAreBoundedAndCannotSelectExecutionModes() throws {
        let args = ["--request", "/synthetic/quote.json", "--model-dir", "/synthetic/model",
            "--membership-epoch", UUID().uuidString, "--rank", "0", "--deadline-uptime-nanoseconds", "300000000001"]
        _ = try GLM5NextCalibrationQuoteCommand.Options(args, now: 1)
        XCTAssertThrowsError(try GLM5NextCalibrationQuoteCommand.Options(args, now: 300000000001))
        XCTAssertThrowsError(try GLM5NextCalibrationQuoteCommand.Options(args + ["--mtp-depth", "1"], now: 1))
        var changed = args; changed[1] = "/synthetic/../quote.json"
        XCTAssertThrowsError(try GLM5NextCalibrationQuoteCommand.Options(changed, now: 1))
        changed = args; changed[9] = "300000000002"
        XCTAssertThrowsError(try GLM5NextCalibrationQuoteCommand.Options(changed, now: 1))
    }

    func test2048QuoteBoundsDigestAndEnvironmentRemainBound() throws {
        let f = Fixture(), original = f.object
        func expanded(prompt: Int = 2048, chunk: Int = 2048, output: Int = 16, context: Int = 2064) throws -> [String: Any] {
            var object = original, selection = try XCTUnwrap(original["selection"] as? [String: Any])
            selection["maximumPromptTokens"] = prompt; selection["maximumChunkTokens"] = chunk
            selection["maximumOutputTokens"] = output; selection["maximumContextTokens"] = context
            object["selection"] = selection
            var authorization = try XCTUnwrap(original["authorization"] as? [String: Any])
            authorization["promptTokenIDs"] = Array(repeating: 1, count: prompt)
            authorization["chunkSize"] = chunk; authorization["outputCount"] = output
            object["authorization"] = authorization
            return object
        }
        let full = try expanded(), verified = try f.decode(f.signed(full))
        let old = try f.decode(f.signed(original))
        XCTAssertEqual(verified.request.selection.maximumContextTokens, 2064)
        XCTAssertEqual(verified.request.authorization.promptTokenIDs.count, 2048)
        XCTAssertEqual(verified.request.authorization.requestID, old.request.authorization.requestID)
        XCTAssertEqual(verified.request.peerIdentitySHA256, old.request.peerIdentitySHA256)
        XCTAssertEqual(verified.request.appSHA256, old.request.appSHA256)
        XCTAssertEqual(verified.requestSHA256, try GLM5NextWorkerQualification.hash(verified.request))
        XCTAssertNotEqual(verified.requestSHA256, old.requestSHA256)
        let environment = ["JACCL_RANK": "0", "DARKBLOOM_GLM_CALIBRATION_APP_SHA256": verified.request.appSHA256,
            "DARKBLOOM_GLM_CALIBRATION_PEER_SHA256": verified.request.peerIdentitySHA256]
        try Wire.requireEnvironment(environment, request: verified.request)
        var injected = environment; injected["MLX_UNBOUND"] = "1"
        XCTAssertThrowsError(try Wire.requireEnvironment(injected, request: verified.request))
        for (prompt, chunk, output, context) in [(2049, 2048, 16, 2064), (2048, 2049, 16, 2064),
            (2048, 2048, 17, 2064), (2048, 2048, 16, 2063), (2048, 2048, 16, 2065)] {
            XCTAssertThrowsError(try f.decode(f.signed(expanded(prompt: prompt, chunk: chunk, output: output, context: context))))
        }
        XCTAssertThrowsError(try f.decode(f.signed(full), now: 1200))
        XCTAssertThrowsError(try f.decode(f.signed(full), peerKey: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertThrowsError(try f.decode(f.signed(full, domain: GLM5NextCalibrationCommand.domain)))
    }

}
