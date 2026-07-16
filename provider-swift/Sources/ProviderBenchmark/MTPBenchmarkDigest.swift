import CryptoKit
import Foundation

enum MTPBenchmarkDigest {
    private static let artifactDomain = Data(
        "darkbloom.mtp.artifact-fingerprint.v1".utf8)
    private static let tokenDomain = Data(
        "darkbloom.mtp.generated-token-sequence.v1".utf8)

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func artifactFingerprint(
        modelID: String,
        revision: String?,
        configSizeBytes: Int64,
        configSHA256: String,
        weightFiles: [MTPBenchmarkArtifactFacts.WeightFile]
    ) -> String {
        var payload = artifactDomain
        append(modelID, to: &payload)
        append(revision ?? "", to: &payload)
        append(String(configSizeBytes), to: &payload)
        append(configSHA256, to: &payload)
        for weight in weightFiles.sorted(by: { $0.name < $1.name }) {
            append(weight.name, to: &payload)
            append(String(weight.sizeBytes), to: &payload)
            append(weight.identityKind.rawValue, to: &payload)
            append(weight.contentIdentity, to: &payload)
        }
        return sha256(payload)
    }

    /// The salt is intentionally never persisted. Digests compare sequences
    /// inside one report without creating a reusable token-sequence oracle.
    static func opaqueTokenDigest(tokenIDs: [Int], salt: Data) -> String {
        var payload = tokenDomain
        append(salt, to: &payload)
        append(String(tokenIDs.count), to: &payload)
        for tokenID in tokenIDs {
            var encoded = Int64(tokenID).bigEndian
            withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
        }
        return sha256(payload)
    }

    static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        var count = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
