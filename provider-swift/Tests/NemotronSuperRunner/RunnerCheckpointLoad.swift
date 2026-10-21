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
            log.emit("load.fit", await fitJSON(transaction, budget: budget, loaded: true).asFields)
        } catch {
            phases.finish("native_load", start: started, outcome: "failed")
            log.emit("load.fit", await fitJSON(transaction, budget: budget, loaded: false).asFields)
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
            "fit": await fitJSON(transaction, budget: budget, loaded: true),
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

    /// Each configuration the LOAD gate weighed (`NemotronSuperLoadFit`) with
    /// the gate's own terms: the gate admits a claim and its slack within
    /// min(cap - used, system available - system reserve), less the
    /// activation reserve and unmaterialized commitments
    /// (`loadClaimRemainingBytes`); the provider's load reserve is not among
    /// them. `served_requests` is the admitted configuration's width only when
    /// the load completed; `admitted` alone means the gate accepted that claim,
    /// and `lost_after_installation` that the builder then refused its owner
    /// beside the installed weights. Any later attempt reused them; its
    /// `claim_bytes` stays the whole claim, though the gate weighed it less
    /// the resident payloads.
    private static func fitJSON(_ transaction: NemotronSuperLocalLoad, budget: GlobalKVCacheBudget,
                                loaded: Bool) async -> RunnerJSON {
        let attempts = await transaction.fitAttempts
        let headroom = budget.memoryHeadroomSnapshot()
        return [
            "attempts": .array(attempts.map {
                ["requests": .count($0.requests), "prefix_bank_bytes": .bytes($0.prefixBankBytes),
                 "chunk_tokens": .count($0.chunkTokens), "claim_bytes": .bytes($0.claimBytes),
                 "admitted": .bool($0.admitted), "lost_after_installation": .bool($0.lostAfterInstallation)]
            }),
            "served_requests": loaded ? attempts.last(where: \.admitted).map { .count($0.requests) } ?? .null : .null,
            "admission_slack_bytes": .bytes(NemotronSuperLoadFit.admissionSlackBytes),
            "system_reserve_bytes": .bytes(NemotronSuperLoadFit.systemReserveBytes(
                configReserveBytes: budget.configReserveBytes)),
            "minimum_available_bytes": .bytes(NemotronSuperLoadFit.minimumAvailableBytes),
            "load_reserve_bytes": .bytes(budget.loadReserveBytes),
            "available_for_load_gb": .double(budget.availableForLoadGb()),
            "ledger": RunnerMemorySampler.ledger(headroom),
        ]
    }
}
