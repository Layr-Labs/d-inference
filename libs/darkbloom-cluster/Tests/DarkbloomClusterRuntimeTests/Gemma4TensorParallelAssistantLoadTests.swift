import CryptoKit
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// A Gemma 4 tensor-parallel rank launched with the assistant (`Gemma4TensorParallelAssistantLaunch`): the pinned
/// artifact verified before it is read, what both ranks bind into their load agreement, and what speculative rounds
/// add to a request's charge. CPU only; a synthetic assistant, never a model pass.
@Suite("Gemma 4 tensor-parallel assistant launch", .serialized)
struct Gemma4TensorParallelAssistantLoadTests {
    private static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A synthetic assistant with the catalog's manifest beside it; returns its directory and aggregate.
    private static func artifact() throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemma-assistant-\(UUID().uuidString)")
        try Device.withDefaultDevice(.cpu) { try Gemma4TensorParallelModel.writeSyntheticAssistant(directory: directory) }
        var entries: [[String: Any]] = [], digests = Data(), total = 0
        for name in ["config.json", "model.safetensors"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let digest = SHA256.hash(data: data)
            digests.append(contentsOf: Array(digest))
            entries.append(["path": name, "sha256": digest.map { String(format: "%02x", $0) }.joined(), "size_bytes": data.count])
            total += data.count
        }
        let aggregate = hex(digests)
        let manifest: [String: Any] = ["aggregate_sha256": aggregate, "file_count": 2, "total_size_bytes": total, "files": entries]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return (directory, aggregate)
    }

    @Test func thePinnedArtifactLoadsOnlyAsVerified() throws {
        let (directory, aggregate) = try Self.artifact()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            let launch = Gemma4TensorParallelAssistantLaunch(directory: directory, aggregateSHA256: aggregate, depth: 3)
            let loaded = try Gemma4AssistantCheckpoint.loadVerified(launch, check: {})
            #expect(loaded.payloadBytes > 0)
            // Another aggregate is refused before any weight is read.
            #expect(throws: (any Error).self) {
                try Gemma4AssistantCheckpoint.loadVerified(.init(directory: directory,
                    aggregateSHA256: String(repeating: "0", count: 64), depth: 3), check: {})
            }
            // Weights the manifest does not name are refused (the model would read them).
            try Data([0]).write(to: directory.appendingPathComponent("extra.safetensors"))
            #expect(throws: (any Error).self) { try Gemma4AssistantCheckpoint.loadVerified(launch, check: {}) }
            try FileManager.default.removeItem(at: directory.appendingPathComponent("extra.safetensors"))
            // A changed weight file is refused.
            let weights = directory.appendingPathComponent("model.safetensors")
            var bytes = try Data(contentsOf: weights)
            bytes[bytes.count - 1] ^= 1
            try bytes.write(to: weights)
            #expect(throws: (any Error).self) { try Gemma4AssistantCheckpoint.loadVerified(launch, check: {}) }
        }
    }

    /// A plain load's agreement is unchanged; the assistant adds its terms, depth and artifact, so ranks launched
    /// with different ones refuse each other.
    @Test func theLoadAgreementNamesTheAssistantOnlyWhenLaunchedWithIt() throws {
        let plain = Gemma4TensorParallelLoadAgreement()
        let launch = Gemma4TensorParallelAssistantLaunch(directory: URL(fileURLWithPath: "/a"),
            aggregateSHA256: String(repeating: "a", count: 64), depth: 3)
        let assisted = Gemma4TensorParallelLoadAgreement(assistant: launch.agreementFields)
        #expect(assisted.fields == plain.fields + launch.agreementFields)
        #expect(!plain.fields.contains { $0.hasPrefix("gemma4-tp-assistant") })
        let deeper = Gemma4TensorParallelLoadAgreement(assistant: Gemma4TensorParallelAssistantLaunch(directory: URL(fileURLWithPath: "/b"),
            aggregateSHA256: String(repeating: "a", count: 64), depth: 2).agreementFields)
        #expect(try assisted.fingerprint(admission: "x") != deeper.fingerprint(admission: "x"))
        #expect(try assisted.fingerprint(admission: "x") != plain.fingerprint(admission: "x"))
        // The local directory is never part of it: each rank names its own copy.
        let elsewhere = Gemma4TensorParallelLoadAgreement(assistant: Gemma4TensorParallelAssistantLaunch(directory: URL(fileURLWithPath: "/c"),
            aggregateSHA256: String(repeating: "a", count: 64), depth: 3).agreementFields)
        #expect(try assisted.fingerprint(admission: "x") == elsewhere.fingerprint(admission: "x"))
    }

    /// Rounds charge each request their own state: none without the assistant, more with a longer context.
    @Test func roundsChargeTheirMirrorAndRows() throws {
        let bound: (Int) throws -> Int = { $0 }
        #expect(try Gemma4TensorParallelRequestBudget.speculativeBytes(depth: 0, contextTokens: 8192, allocationBound: bound) == 0)
        let short = try Gemma4TensorParallelRequestBudget.speculativeBytes(depth: 3, contextTokens: 8192, allocationBound: bound)
        let long = try Gemma4TensorParallelRequestBudget.speculativeBytes(depth: 3, contextTokens: 65536, allocationBound: bound)
        // Every head of the full layer, keys and values in BF16, twice: 8 KB a token.
        #expect(long - short >= (65536 - 8192) * 2 * 512 * 2 * 2 * 2)
        let plain = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 8192, chunkTokens: 512, allocationBound: bound)
        let assisted = try Gemma4TensorParallelRequestBudget.derive(contextTokens: 8192, chunkTokens: 512, speculativeDepth: 3,
                                                                    allocationBound: bound)
        #expect(assisted.requestBytes == plain.requestBytes + short && plain.speculativeBytes == 0)
    }
}
