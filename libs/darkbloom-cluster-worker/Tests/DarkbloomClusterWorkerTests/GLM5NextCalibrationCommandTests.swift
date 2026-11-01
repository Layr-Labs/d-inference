import CryptoKit
import Foundation
import DarkbloomClusterRuntime
import XCTest
@testable import DarkbloomClusterWorker

final class GLM5NextCalibrationCommandTests: XCTestCase {
    typealias Q = GLM5NextWorkerQualification
    let epoch = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    func configuration(extra: [String] = []) throws -> WorkerConfiguration {
        try .init(arguments: ["--model-dir", "/synthetic/model", "--rank", "0", "--stage-cut", "22",
            "--membership-epoch", epoch.uuidString.lowercased(), "--model-id", Q.modelID,
            "--artifact-sha256", "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac",
            "--configuration-sha256", "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b",
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "120000000100", "--glm-qualification", "/synthetic/authority.json",
            "--qualification-switches", "yes", "--keep-warm", "off", "--data-plane", "encrypted_v1"] + extra, now: 100)
    }
    func payload() throws -> GLM5NextCalibrationCommand.Payload {
        .init(selection: .init(version: 1, epoch: epoch, rank: 0, expiresUnixSeconds: 1200,
            repository: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp",
            revision: "8841c52a1e8400bd7d3e7e631c916a6c4e6757b0",
            files: ["config.json": .init(bytes: 10023646, sha256: "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b"),
                    "model.safetensors.index.json": .init(bytes: 12351468, sha256: "b6cdec53a012ec4a8b383d37224f5955d463ec244d80b43d24fac72aa4c07b47")],
            artifactSHA256: "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac", cut: 22, profileID: "test",
            maximumPromptTokens: 32, maximumChunkTokens: 8, maximumOutputTokens: 4, maximumContextTokens: 64,
            policy: "serving_v1", storage: "nvfp4Hybrid", loadCapacityBytes: 1 << 30,
            requestCapacityBytes: 64 << 20, hostAllocationQuantum: 4096, hostAllocationOverhead: 128,
            environment: .init(binarySHA256: String(repeating: "c", count: 64),
                metallibSHA256: String(repeating: "d", count: 64), backend: "jaccl",
                allocator: "disableFreedBufferCache", os: "test", deviceRegistryID: 1, deviceName: "test",
                architecture: "test", maximumBufferBytes: 1 << 30, recommendedWorkingSetBytes: 2 << 30,
                memoryBytes: 2 << 30, variableSHA256: [:]), workspaceEvidence: Data()),
            authorization: try .init(requestID: UUID(), nativeHardCapBytes: 1 << 30, hostBudgetBytes: 64 << 20, osHeadroomBytes: 64 << 20,
                workspaceNativeAllowanceBytes: 1 << 20, workspaceHostAllowanceBytes: 1 << 20,
                promptTokenIDs: [1, 2], outputCount: 2, chunkSize: 2), binding: try wireBinding())
    }
    // Claim syntax for decoder tests, not a manufactured metadata contract.
    func wireBinding() throws -> GLM5NextCalibration.Binding {
        let object: [String: Any] = ["profile": ["id": "test", "vocabularySize": 512,
            "maximumPromptTokens": 32, "maximumOutputTokens": 4,
            "maximumChunkTokens": 8, "maximumContextTokens": 64],
            "executionPlanSHA256": String(repeating: "e", count: 64)]
        return try JSONDecoder().decode(GLM5NextCalibration.Binding.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    func testSignatureScopeCapacityAndBackendRefusalsBeforeNativeWork() throws {
        let key = P256.Signing.PrivateKey(), config = try configuration()
        let bytes = try JSONEncoder().encode(payload())
        func signed(_ bytes: Data, domain: Data = GLM5NextCalibrationCommand.domain) throws -> Data {
            try JSONEncoder().encode(Q.SignedDocument(payload: bytes,
                signature: key.signature(for: domain + bytes).rawRepresentation))
        }
        func decode(_ data: Data, publicKey: Data? = nil, now: Int64 = 1000) throws {
            _ = try GLM5NextCalibrationCommand.decode(data,
                memberPublicKey: publicKey ?? key.publicKey.x963Representation, configuration: config, now: now)
        }
        try decode(signed(bytes))
        XCTAssertThrowsError(try decode(signed(bytes), publicKey: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertThrowsError(try decode(signed(bytes, domain: Q.domain)))
        XCTAssertThrowsError(try decode(signed(bytes), now: 1200))
        XCTAssertThrowsError(try decode(Data(repeating: 0, count: (256 << 10) + 1)))
        for (field, value) in [("rank", 1), ("cut", 23), ("loadCapacityBytes", Int.max), ("maximumPromptTokens", 2049)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var selection = try XCTUnwrap(object["selection"] as? [String: Any]); selection[field] = value
            object["selection"] = selection
            XCTAssertThrowsError(try decode(signed(JSONSerialization.data(withJSONObject: object))))
        }
        XCTAssertThrowsError(try configuration(extra: ["--mtp-depth", "1"]))
        XCTAssertThrowsError(try configuration(extra: ["--prefill-schedule", "wavefront_v1"]))
        // Invalid authorization is refused without installing process-wide state.
        XCTAssertThrowsError(try GLM5NextCalibrationNativeCap.install(bytes: 0))
        XCTAssertThrowsError(try GLM5NextCalibrationNativeCap.requireInstalled(bytes: -1))
    }
    func testMissingUnknownAndCrossedBindingFieldsRefuseBeforeNativeWork() throws {
        let key = P256.Signing.PrivateKey(), config = try configuration()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload())) as? [String: Any])
        func refuse(_ object: [String: Any]) throws {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let document = try JSONEncoder().encode(Q.SignedDocument(payload: bytes,
                signature: key.signature(for: GLM5NextCalibrationCommand.domain + bytes).rawRepresentation))
            XCTAssertThrowsError(try GLM5NextCalibrationCommand.decode(document,
                memberPublicKey: key.publicKey.x963Representation, configuration: config, now: 1000))
        }
        var missing = original; missing.removeValue(forKey: "binding"); try refuse(missing)
        var rootUnknown = original; rootUnknown["ordinaryQualification"] = true; try refuse(rootUnknown)
        let binding = try XCTUnwrap(original["binding"] as? [String: Any])
        for key in binding.keys {
            var changed = binding; changed.removeValue(forKey: key)
            var root = original; root["binding"] = changed; try refuse(root)
        }
        for (key, value) in [("executionPlanSHA256", "invalid"), ("unknown", "refuse")] {
            var changed = binding; changed[key] = value
            var root = original; root["binding"] = changed; try refuse(root)
        }
        let profile = try XCTUnwrap(binding["profile"] as? [String: Any])
        for key in profile.keys {
            var changed = profile; changed.removeValue(forKey: key)
            var nested = binding; nested["profile"] = changed
            var root = original; root["binding"] = nested; try refuse(root)
        }
        let changes: [(String, Any)] = [("id", "other"), ("vocabularySize", 0),
            ("maximumPromptTokens", 33), ("maximumOutputTokens", 5),
            ("maximumChunkTokens", 7), ("maximumContextTokens", 65), ("unknown", true)]
        for (key, value) in changes {
            var changed = profile; changed[key] = value
            var nested = binding; nested["profile"] = changed
            var root = original; root["binding"] = nested; try refuse(root)
        }
    }


    func testSigned2048ScopeRequiresMatchingBindingAndRetainsAuthorityChecks() throws {
        let key = P256.Signing.PrivateKey(), config = try configuration()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload())) as? [String: Any])
        func expanded(prompt: Int = 2048, chunk: Int = 2048, output: Int = 16, context: Int = 2064) throws -> [String: Any] {
            var object = original
            var selection = try XCTUnwrap(object["selection"] as? [String: Any])
            var binding = try XCTUnwrap(object["binding"] as? [String: Any])
            var profile = try XCTUnwrap(binding["profile"] as? [String: Any])
            for (field, value) in [("maximumPromptTokens", prompt), ("maximumChunkTokens", chunk),
                ("maximumOutputTokens", output), ("maximumContextTokens", context)] {
                selection[field] = value; profile[field] = value
            }
            binding["profile"] = profile; object["binding"] = binding; object["selection"] = selection
            var authorization = try XCTUnwrap(object["authorization"] as? [String: Any])
            authorization["promptTokenIDs"] = Array(repeating: 1, count: prompt)
            authorization["chunkSize"] = chunk; authorization["outputCount"] = output
            object["authorization"] = authorization
            return object
        }
        func decode(_ object: [String: Any], domain: Data = GLM5NextCalibrationCommand.domain,
                    now: Int64 = 1000) throws -> GLM5NextCalibrationCommand.Payload {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let signed = try JSONEncoder().encode(Q.SignedDocument(payload: bytes,
                signature: key.signature(for: domain + bytes).rawRepresentation))
            return try GLM5NextCalibrationCommand.decode(signed,
                memberPublicKey: key.publicKey.x963Representation, configuration: config, now: now)
        }
        let full = try expanded(), decoded = try decode(full)
        XCTAssertEqual(decoded.authorization.promptTokenIDs.count, 2048)
        XCTAssertEqual(decoded.binding.profile.maximumContextTokens, 2064)
        XCTAssertEqual(decoded.binding.profile.maximumChunkTokens, 2048)
        let baseline = try JSONDecoder().decode(GLM5NextCalibrationCommand.Payload.self,
            from: JSONSerialization.data(withJSONObject: original))
        XCTAssertEqual(decoded.authorization.requestID, baseline.authorization.requestID)
        XCTAssertEqual(decoded.authorization.nativeHardCapBytes, baseline.authorization.nativeHardCapBytes)
        XCTAssertEqual(decoded.binding.executionPlanSHA256, baseline.binding.executionPlanSHA256)
        XCTAssertEqual(try Q.hash(decoded.selection.environment), try Q.hash(baseline.selection.environment))
        for (prompt, chunk, output, context) in [(2049, 2048, 16, 2064), (2048, 2049, 16, 2064),
            (2048, 2048, 17, 2064), (2048, 2048, 16, 2063), (2048, 2048, 16, 2065)] {
            XCTAssertThrowsError(try decode(expanded(prompt: prompt, chunk: chunk, output: output, context: context)))
        }
        var stale = full; stale["binding"] = original["binding"]
        XCTAssertThrowsError(try decode(stale))
        XCTAssertThrowsError(try decode(full, domain: Q.domain))
        XCTAssertThrowsError(try decode(full, now: 1200))
        for (field, value) in [("rank", 1), ("cut", 23), ("loadCapacityBytes", Int.max)] {
            var changed = full, selection = try XCTUnwrap(full["selection"] as? [String: Any])
            selection[field] = value; changed["selection"] = selection
            XCTAssertThrowsError(try decode(changed))
        }
    }

}
