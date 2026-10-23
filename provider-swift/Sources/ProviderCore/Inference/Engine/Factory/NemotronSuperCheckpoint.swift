// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLMCommon
import MLXVLM

/// A pinned Super checkpoint directory, opened for the managed load and the
/// qualification runner. `Inputs` reads only small metadata files; `open`
/// then streams every shard against its pinned SHA-256 before any tensor
/// header is parsed. No weights are allocated here.
enum NemotronSuperCheckpoint {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unpinnedIndex
        case configuration(String)
        case shards(missing: Int)
        case unpinnedShard(String)

        var description: String {
            switch self {
            case .unpinnedIndex: "model.safetensors.index.json is not the pinned index"
            case .configuration(let detail): detail
            case .shards(let missing): "\(missing) shard(s) missing, unpinned or not regular files"
            case .unpinnedShard(let name): "shard \(name) is not pinned"
            }
        }
    }

    /// Identity and configuration, checked before any shard is read: pinned
    /// index, pinned template, parseable Super configuration, inventory, EOS
    /// ids and the per-token KV rate.
    struct Inputs {
        let configData: Data
        let indexData: Data
        let indexSHA256: String
        let templateBytes: Data
        let eosTokenIDs: Set<Int>
        /// Full-attention layers x (K+V) x KV heads x head_dim x 2 bytes (fp16),
        /// the `SlotSizingSnapshot` convention; Mamba state is not per-token.
        let fp16KVBytesPerToken: Int
        let inventory: NemotronSuperCheckpointInventory

        init(directory: URL, templateURL: URL? = nil) throws {
            configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            indexData = try Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))
            indexSHA256 = SHA256.hash(data: indexData).map { String(format: "%02x", $0) }.joined()
            guard indexSHA256 == NemotronSuperCheckpointPin.index else { throw Failure.unpinnedIndex }
            templateBytes = try Data(contentsOf: templateURL ?? directory.appendingPathComponent("chat_template.jinja"))
            _ = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
            // NemotronSuperLocalLoad parses this again after its own identity
            // check; parsing here fails fast on a size or schema bound.
            _ = try NemotronSuperImageConfiguration(data: configData)
            let generation = try? Data(contentsOf: directory.appendingPathComponent("generation_config.json"))
            (eosTokenIDs, fp16KVBytesPerToken) = try Self.facts(configData: configData,
                generationConfigData: generation)
            inventory = try NemotronSuperCheckpointInventory(indexData: indexData)
            let missing = inventory.shards.filter { name in
                let values = try? directory.appendingPathComponent(name)
                    .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile != true || values?.isSymbolicLink == true
                    || NemotronSuperCheckpointPin.shards[name] == nil
            }
            guard missing.isEmpty else { throw Failure.shards(missing: missing.count) }
        }

        private static func facts(configData: Data, generationConfigData: Data?) throws
            -> (eos: Set<Int>, kvRate: Int) {
            guard let root = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
                let text = root["llm_config"] as? [String: Any],
                let blocks = text["layers_block_type"] as? [String],
                let kvHeads = text["num_key_value_heads"] as? Int,
                let headDim = text["head_dim"] as? Int
            else { throw Failure.configuration("config.json lacks llm_config attention geometry") }
            let attention = blocks.filter { $0 == "attention" }.count
            guard attention > 0, kvHeads > 0, headDim > 0 else {
                throw Failure.configuration("config.json attention geometry is empty")
            }
            var eos = Set<Int>()
            func collect(_ value: Any?) {
                if let id = value as? Int { eos.insert(id) }
                if let ids = value as? [Int] { eos.formUnion(ids) }
            }
            collect(root["eos_token_id"])
            collect(text["eos_token_id"])
            if let generationConfigData,
                let generation = try JSONSerialization.jsonObject(with: generationConfigData) as? [String: Any] {
                collect(generation["eos_token_id"])
            }
            guard !eos.isEmpty else { throw Failure.configuration("no eos_token_id in configuration") }
            return (eos, attention * 2 * kvHeads * headDim * 2)
        }
    }

    /// Inputs plus every shard opened against its pin and bound to the index.
    struct Opened {
        let inputs: Inputs
        let source: ModelOptCheckpointSource
        /// All checkpoint tensors, the embedded head and retained metadata
        /// included: an upper bound of the installed resident payload.
        let tensorBytes: Int
    }

    static func open(directory: URL, parallelism: Int = 4,
        progress: (@Sendable (_ verified: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Opened {
        let inputs = try Inputs(directory: directory)
        let files = try await openShards(directory: directory, names: inputs.inventory.shards,
            parallelism: parallelism, progress: progress)
        let source = try ModelOptCheckpointSource(indexData: inputs.indexData,
            indexSHA256: inputs.indexSHA256, files: files)
        let tensorBytes = source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        return Opened(inputs: inputs, source: source, tensorBytes: tensorBytes)
    }

    /// `ModelOptTensorFile` streams each whole shard against its pinned SHA-256
    /// before parsing; bounded parallelism only overlaps that I/O and hashing.
    static func openShards(directory: URL, names: [String], parallelism: Int,
        progress: (@Sendable (_ verified: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [String: ModelOptTensorFile] {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var files: [String: ModelOptTensorFile] = [:]
        }
        let collected = Collected()
        var pending = names[...]
        try await withThrowingTaskGroup(of: Void.self) { group in
            func submit(_ name: String) throws {
                guard let sha256 = NemotronSuperCheckpointPin.shards[name] else {
                    throw Failure.unpinnedShard(name)
                }
                let url = directory.appendingPathComponent(name)
                group.addTask {
                    let file = try ModelOptTensorFile(url: url, sha256: sha256)
                    collected.lock.withLock { collected.files[name] = file }
                }
            }
            for _ in 0..<max(1, parallelism) {
                guard let name = pending.popFirst() else { break }
                try submit(name)
            }
            var done = 0
            while try await group.next() != nil {
                done += 1
                progress?(done, names.count)
                if let name = pending.popFirst() { try submit(name) }
            }
        }
        return collected.lock.withLock { collected.files }
    }
}
