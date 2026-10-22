import CryptoKit
import Foundation
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity

/// Quote authority is deliberately unusable as experiment/serving authority.
enum GLM5NextCalibrationQuoteWire {
    static let domain = Data("darkbloom/glm-calibration-quote/v1\0".utf8)
    struct Selection: Codable {
        let version: Int
        let epoch: UUID
        let rank: Int
        let expiresUnixSeconds: Int64
        let repository: String
        let revision: String
        let files: [String: GLM5NextWorkerQualification.File]
        let artifactSHA256: String
        let cut: Int
        let profileID: String
        let maximumPromptTokens: Int
        let maximumChunkTokens: Int
        let maximumOutputTokens: Int
        let maximumContextTokens: Int
        let policy: String
        let storage: String
        let mode: String
        let hostAllocationQuantum: Int
        let hostAllocationOverhead: Int
        let environment: GLM5NextWorkerQualification.Environment
    }
    struct Request: Codable {
        let quoteRequestID: UUID
        let peerIdentitySHA256: String
        let appSHA256: String
        let selection: Selection
        let authorization: GLM5NextCalibration.Authorization
    }
    struct Verified {
        let request: Request
        /// Canonical decoded payload, matching the runtime's evidence hash rules.
        let requestSHA256: String
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func invalid(_ message: String) -> WorkerFailure { .invalid("GLM quotation: " + message) }

    static func requireEnvironment(_ actual: [String: String], request: Request) throws {
        // Foundation supplies this exact CoreFoundation key in a launched child,
        // even when Process.environment was explicit. Model variables stay bound.
        let ordinary: Set<String> = ["PATH", "LANG", "LC_ALL", "JACCL_RANK", "JACCL_IBV_DEVICES", "JACCL_COORDINATOR",
            "__CF_USER_TEXT_ENCODING"]
        let permitted = { (key: String) in
            ordinary.contains(key) || key.hasPrefix("MLX_") || key.hasPrefix("DARKBLOOM_")
        }
        guard actual.count <= 128,
              actual.keys.allSatisfy(permitted),
              actual["JACCL_RANK"] == String(request.selection.rank),
              actual["DARKBLOOM_GLM_CALIBRATION_APP_SHA256"] == request.appSHA256,
              actual["DARKBLOOM_GLM_CALIBRATION_PEER_SHA256"] == request.peerIdentitySHA256,
              actual.filter({ $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_") })
                .mapValues({ hash(Data($0.utf8)) }) == request.selection.environment.variableSHA256 else {
            let names = actual.keys.filter { !permitted($0) }.sorted().prefix(16)
                .map { String($0.prefix(64)) }.joined(separator: ", ")
            throw invalid("Execution environment differs from quote authority; unexpected keys: \(names.isEmpty ? "none" : names)")
        }
    }

    /// Pure verification: no filesystem, native initialization or device query.
    static func decode(_ data: Data, memberPublicKey: Data, peerPublicKey: Data,
                       epoch: UUID, rank: Int, now: Int64) throws -> Verified {
        guard !data.isEmpty, data.count <= 256 << 10 else { throw invalid("Envelope exceeds bound") }
        let envelope = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: data)
        guard !envelope.payload.isEmpty, envelope.payload.count <= 128 << 10,
              envelope.signature.count == 64 else { throw invalid("Payload exceeds bound") }
        let key = try P256.Signing.PublicKey(x963Representation: memberPublicKey)
        _ = try ClusterDataPlanePin(identityPublicKey: peerPublicKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: envelope.signature)
        guard memberPublicKey != peerPublicKey, key.isValidSignature(signature, for: domain + envelope.payload) else {
            throw invalid("Member signature differs")
        }
        let request = try JSONDecoder().decode(Request.self, from: envelope.payload)
        // Reject extra mode/authority fields rather than silently ignoring them.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(request)
        func sameKeys(_ original: Any, _ decoded: Any) -> Bool {
            if let a = original as? [String: Any], let b = decoded as? [String: Any] {
                return Set(a.keys) == Set(b.keys) && a.allSatisfy { sameKeys($0.value, b[$0.key]!) }
            }
            if let a = original as? [Any], let b = decoded as? [Any] {
                return a.count == b.count && zip(a, b).allSatisfy { sameKeys($0.0, $0.1) }
            }
            return true
        }
        guard sameKeys(try JSONSerialization.jsonObject(with: envelope.payload),
                       try JSONSerialization.jsonObject(with: canonical)) else { throw invalid("Unknown request fields") }
        let p = request.selection, a = request.authorization, e = p.environment
        try a.validate()
        try GLM5NextCalibration.requirePinnedSelection(repository: p.repository, revision: p.revision,
            aggregate: p.artifactSHA256, configurationSHA256: p.files["config.json"]?.sha256,
            indexSHA256: p.files["model.safetensors.index.json"]?.sha256)
        guard p.version == 1, (0...1).contains(rank), p.rank == rank, p.epoch == epoch,
              now >= 0, p.expiresUnixSeconds > now, p.expiresUnixSeconds - now <= 3600,
              p.mode == "coldTextBatch1", p.policy == "serving_v1", p.storage == "nvfp4Hybrid",
              (1..<45).contains(p.cut), !p.profileID.isEmpty, p.profileID.utf8.count <= 128,
              (1...2048).contains(p.maximumPromptTokens), (1...p.maximumPromptTokens).contains(p.maximumChunkTokens),
              (1...16).contains(p.maximumOutputTokens),
              p.maximumContextTokens >= p.maximumPromptTokens + p.maximumOutputTokens, p.maximumContextTokens <= 2064,
              a.promptTokenIDs.count <= p.maximumPromptTokens, a.chunkSize <= p.maximumChunkTokens,
              a.outputCount <= p.maximumOutputTokens,
              (1...(1 << 30)).contains(p.hostAllocationQuantum), (0...(1 << 30)).contains(p.hostAllocationOverhead),
              a.nativeHardCapBytes + a.hostBudgetBytes <= e.memoryBytes,
              a.osHeadroomBytes < e.memoryBytes - a.nativeHardCapBytes - a.hostBudgetBytes,
              e.backend == "jaccl", e.allocator == "disableFreedBufferCache",
              isHash(e.binarySHA256), isHash(e.metallibSHA256), isHash(request.appSHA256),
              request.peerIdentitySHA256 == hash(peerPublicKey),
              e.variableSHA256["DARKBLOOM_GLM_CALIBRATION_APP_SHA256"] == hash(Data(request.appSHA256.utf8)),
              e.variableSHA256["DARKBLOOM_GLM_CALIBRATION_PEER_SHA256"] == hash(Data(request.peerIdentitySHA256.utf8)),
              !e.os.isEmpty, !e.deviceName.isEmpty, !e.architecture.isEmpty,
              e.maximumBufferBytes > 0, e.recommendedWorkingSetBytes > 0,
              e.variableSHA256.count <= 128,
              e.variableSHA256.allSatisfy({ ($0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")) && isHash($0.value) }),
              (3...258).contains(p.files.count), p.files.allSatisfy({ name, file in
                  !name.isEmpty && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\")
                      && name != "." && name != ".." && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                      && file.bytes > 0 && isHash(file.sha256)
              }) else { throw invalid("Identity, scope or capacity differs") }
        return Verified(request: request, requestSHA256: hash(canonical))
    }
}
