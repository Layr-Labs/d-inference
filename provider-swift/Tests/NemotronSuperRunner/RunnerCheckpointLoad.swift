import CryptoKit
import Foundation
import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

/// Loads the pinned full checkpoint through the real unpublished transaction
/// (NemotronSuperLocalLoad: config identity, CPU quote, pending LOAD claim,
/// fenced staging, bridge construction, LOAD finish) on the real process budget.
enum RunnerCheckpointLoad {
    static func load(directory: URL, templateURL: URL?, settings: RunnerLoadSettings,
        budget: GlobalKVCacheBudget, log: RunnerEventLog, phases: RunnerLoadPhases
    ) async throws -> RunnerServing {
        // Resolved before any shard read; the load transaction parses the same entries.
        let speculation = try settings.speculation()
        let inputs = try RunnerCheckpointInputs(directory: directory, templateURL: templateURL)
        let configData = inputs.configData, indexSHA256 = inputs.indexSHA256
        let templateBytes = inputs.templateBytes, facts = inputs.facts
        let files = try await phases.run("verify_shards") {
            try await verifiedShards(directory: directory, names: inputs.inventory.shards,
                parallelism: settings.verifyParallelism, log: log)
        }
        let shardCount = files.count
        let source = try ModelOptCheckpointSource(indexData: inputs.indexData, indexSHA256: indexSHA256, files: files)
        let quote = try NemotronSuperInstallation.requiredLoadBytes(
            source: source, backendAllowanceBytes: settings.backendAllowanceBytes)
        let tensorBytes = source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        log.emit("load.quote", ["load_quote_bytes": .bytes(quote), "checkpoint_tensor_bytes": .bytes(tensorBytes),
            "pending_load_claim_bytes": .bytes(quote + settings.kvCapacityBytes)])
        let tokenizer = try await phases.run("tokenizer") {
            TokenizerHandle(try await LocalTokenizerLoader().load(from: directory))
        }
        // weightsBytes is an upper bound (all checkpoint tensors, MTP included);
        // the builder only requires it to cover the installed resident payload.
        let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes,
            fp16KVBytesPerToken: try settings.kvBytesPerToken(configured: facts.fp16KVBytesPerToken),
            maxContextLength: settings.maxContextLength, defaultMaxTokens: settings.defaultMaxTokens)
        let transaction = NemotronSuperLocalLoad(budget: budget)
        let bridge: EngineV2Bridge
        let started = phases.begin("native_load")
        do {
            bridge = try await transaction.load(configData: configData, source: source, tokenizer: tokenizer,
                eosTokenIDs: facts.eosTokenIDs, sizing: sizing, kvBytesCapacity: settings.kvCapacityBytes,
                backendAllowanceBytes: settings.backendAllowanceBytes, environment: settings.engineEnvironment)
            phases.finish("native_load", start: started, outcome: "ok")
        } catch {
            phases.finish("native_load", start: started, outcome: "failed")
            log.emit("load.transaction", ["phase": .string(String(describing: await transaction.phase))])
            throw error
        }
        let hook: NemotronSuperLocalImageHTTP
        do {
            hook = try await transaction.localImageHTTP(templateBytes: templateBytes)
        } catch {
            // Nothing has been served; retire the loaded owner before failing.
            try? await transaction.closeAfterDrain()
            throw error
        }
        let identity = inputs.json.merging([
            "mode": "checkpoint", "checkpoint_dir": .string(directory.path),
            "shards_verified": .count(shardCount), "load_quote_bytes": .bytes(quote),
            "checkpoint_tensor_bytes": .bytes(tensorBytes),
            "fp16_kv_bytes_per_token": .bytes(sizing.fp16KVBytesPerToken), "image_hook": true,
            "speculation": RunnerLoadSettings.speculationJSON(speculation),
            "kv_grant": await RunnerKVGrant.json(bridge: bridge, grantBytes: settings.kvCapacityBytes),
        ])
        return RunnerServing(bridge: bridge, tokenizer: tokenizer, imageHook: hook, identity: identity,
            retire: {
                try await transaction.closeAfterDrain()
                let residency = await transaction.residencySnapshot
                return ["transaction_phase": .string(String(describing: await transaction.phase)),
                        "installation_residency_used_bytes": residency.map { .bytes($0.usedBytes) } ?? .null]
            })
    }

    /// ModelOptTensorFile streams each whole shard against its pinned SHA-256
    /// before parsing; bounded parallelism only overlaps that I/O and hashing.
    private static func verifiedShards(directory: URL, names: [String], parallelism: Int,
        log: RunnerEventLog) async throws -> [String: ModelOptTensorFile] {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var files: [String: ModelOptTensorFile] = [:]
        }
        let collected = Collected()
        var pending = names[...]
        try await withThrowingTaskGroup(of: Void.self) { group in
            func submit(_ name: String) throws {
                guard let sha256 = NemotronSuperCheckpointPin.shards[name] else {
                    throw RunnerFailure.checkpoint("shard \(name) is not pinned")
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
                if done % 8 == 0 || done == names.count {
                    log.emit("load.verify_progress", ["verified": .count(done), "total": .count(names.count)])
                }
                if let name = pending.popFirst() { try submit(name) }
            }
        }
        return collected.lock.withLock { collected.files }
    }
}
