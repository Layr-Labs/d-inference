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
        let checkpoint = inputs.checkpoint
        let configData = checkpoint.configData, templateBytes = checkpoint.templateBytes
        let files = try await phases.run("verify_shards") {
            try await NemotronSuperCheckpoint.openShards(directory: directory, names: checkpoint.inventory.shards,
                parallelism: settings.verifyParallelism) { done, total in
                if done % 8 == 0 || done == total {
                    log.emit("load.verify_progress", ["verified": .count(done), "total": .count(total)])
                }
            }
        }
        let shardCount = files.count
        let source = try ModelOptCheckpointSource(indexData: checkpoint.indexData,
            indexSHA256: checkpoint.indexSHA256, files: files)
        let installation = try NemotronSuperInstallation.loadQuote(
            source: source, backendAllowanceBytes: settings.backendAllowanceBytes)
        let quote = installation.totalBytes
        let headQuote = try speculation.map { _ in
            try NemotronSuperMTPServing.loadQuote(
                configuration: try NemotronSuperImageConfiguration(data: configData), source: source)
        }
        // Installation and any head with sequential transients, before the
        // transaction overlaps the transient with its serving room (the
        // charge.opened event records the claim it takes).
        let claim = try NemotronSuperLoadClaim.bytes(installation: installation, head: headQuote,
            sequential: NemotronSuperLoadClaim.mayReturnStagingBuffers())
        let tensorBytes = source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        log.emit("load.quote", ["load_quote_bytes": .bytes(quote), "checkpoint_tensor_bytes": .bytes(tensorBytes),
            "installation_payload_bytes": .bytes(installation.payloadBytes),
            "installation_staging_bytes": .bytes(installation.stagingBytes),
            "head_payload_bytes": headQuote.map { .bytes($0.payloadBytes) } ?? .null,
            "head_construction_bytes": headQuote.map { .bytes($0.constructionBytes) } ?? .null,
            "installation_head_bytes": .bytes(claim),
            "emulated_production_grant_bytes": settings.emulation.map {
                .bytes($0.productionGrantBytes(checkpointBytes: UInt64(tensorBytes)))
            } ?? .null,
            "pending_load_claim_bytes": .bytes(claim + (settings.admissionKVBytes ?? settings.kvCapacityBytes)),
            "admission_kv_bytes": .bytes(settings.admissionKVBytes ?? settings.kvCapacityBytes)])
        let tokenizer = try await phases.run("tokenizer") {
            TokenizerHandle(try await LocalTokenizerLoader().load(from: directory))
        }
        // weightsBytes is an upper bound (all checkpoint tensors, MTP included);
        // the builder only requires it to cover the installed resident payload.
        let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes,
            fp16KVBytesPerToken: try settings.kvBytesPerToken(configured: checkpoint.fp16KVBytesPerToken),
            maxContextLength: settings.maxContextLength, defaultMaxTokens: settings.defaultMaxTokens)
        let transaction = NemotronSuperLocalLoad(budget: budget)
        let bridge: EngineV2Bridge
        let started = phases.begin("native_load")
        do {
            bridge = try await transaction.load(configData: configData, source: source, tokenizer: tokenizer,
                eosTokenIDs: checkpoint.eosTokenIDs, sizing: sizing, kvBytesCapacity: settings.kvCapacityBytes,
                admissionKVBytes: settings.admissionKVBytes,
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
            "request_charge": await RunnerRequestCharge.json(bridge: bridge,
                environment: settings.engineEnvironment, contextTokens: settings.maxContextLength),
        ])
        return RunnerServing(bridge: bridge, tokenizer: tokenizer, imageHook: hook, identity: identity,
            retire: {
                try await transaction.closeAfterDrain()
                let residency = await transaction.residencySnapshot
                return ["transaction_phase": .string(String(describing: await transaction.phase)),
                        "installation_residency_used_bytes": residency.map { .bytes($0.usedBytes) } ?? .null]
            })
    }
}
