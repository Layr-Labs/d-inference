import CryptoKit
import Foundation
import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

func runnerSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Identity and configuration inputs of a checkpoint directory, checked before
/// any shard is read: pinned index, pinned template, parseable Super image
/// configuration, inventory, EOS ids and the per-token KV rate. `--preflight`
/// stops here, so it reads only small JSON/template files.
struct RunnerCheckpointInputs {
    let configData: Data
    let indexData: Data
    let indexSHA256: String
    let templateBytes: Data
    let facts: RunnerCheckpointFacts
    let inventory: NemotronSuperCheckpointInventory

    init(directory: URL, templateURL: URL?) throws {
        configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        indexData = try Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))
        indexSHA256 = runnerSHA256(indexData)
        guard indexSHA256 == NemotronSuperCheckpointPin.index else {
            throw RunnerFailure.checkpoint("model.safetensors.index.json is not the pinned index")
        }
        templateBytes = try Data(contentsOf: templateURL ?? directory.appendingPathComponent("chat_template.jinja"))
        _ = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
        // NemotronSuperLocalLoad parses this again after its own config identity
        // check; parsing here fails fast on a size or schema bound.
        _ = try NemotronSuperImageConfiguration(data: configData)
        let generation = try? Data(contentsOf: directory.appendingPathComponent("generation_config.json"))
        facts = try RunnerCheckpointFacts(configData: configData, generationConfigData: generation)
        inventory = try NemotronSuperCheckpointInventory(indexData: indexData)
        let missing = inventory.shards.filter { name in
            let values = try? directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile != true || values?.isSymbolicLink == true
                || NemotronSuperCheckpointPin.shards[name] == nil
        }
        guard missing.isEmpty else {
            throw RunnerFailure.checkpoint("\(missing.count) shard(s) missing, unpinned or not regular files")
        }
    }

    var json: RunnerJSON {
        [
            "config_sha256": .string(runnerSHA256(configData)),
            "config_bytes": .bytes(configData.count), "index_sha256": .string(indexSHA256),
            "index_pinned": true, "template_sha256": .string(runnerSHA256(templateBytes)),
            "shards": .count(inventory.shards.count), "tensors": .count(inventory.entries.count),
            "mtp_tensors": .count(inventory.entries(for: .mtp).count),
            "fp16_kv_bytes_per_token": .bytes(facts.fp16KVBytesPerToken),
            "eos_token_ids": .array(facts.eosTokenIDs.sorted().map { .count($0) }),
        ]
    }
}

/// Facts read from the checkpoint's own configuration files.
struct RunnerCheckpointFacts {
    let eosTokenIDs: Set<Int>
    /// Full-attention layers x (K+V) x KV heads x head_dim x 2 bytes (fp16), the
    /// SlotSizingSnapshot convention; recurrent Mamba state is not per-token.
    let fp16KVBytesPerToken: Int

    init(configData: Data, generationConfigData: Data?) throws {
        guard let root = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
            let text = root["llm_config"] as? [String: Any],
            let blocks = text["layers_block_type"] as? [String],
            let kvHeads = text["num_key_value_heads"] as? Int,
            let headDim = text["head_dim"] as? Int
        else { throw RunnerFailure.checkpoint("config.json lacks llm_config attention geometry") }
        let attention = blocks.filter { $0 == "attention" }.count
        guard attention > 0, kvHeads > 0, headDim > 0 else {
            throw RunnerFailure.checkpoint("config.json attention geometry is empty")
        }
        fp16KVBytesPerToken = attention * 2 * kvHeads * headDim * 2
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
        guard !eos.isEmpty else { throw RunnerFailure.checkpoint("no eos_token_id in configuration") }
        eosTokenIDs = eos
    }
}
