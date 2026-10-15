import Foundation
import MLX
import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

/// Installs the tiny fixture with the same transaction order as
/// NemotronSuperLocalLoad.load, which pins the real config and index identity
/// and therefore cannot stage a fixture: CPU quote, real pending LOAD claim on
/// the process budget, fenced staging, bridge construction, LOAD finish.
enum RunnerSyntheticLoad {
    static func load(stateDirectory: URL, templateURL: URL, settings: RunnerLoadSettings,
        budget: GlobalKVCacheBudget, log: RunnerEventLog, phases: RunnerLoadPhases
    ) async throws -> RunnerServing {
        let templateBytes = try Data(contentsOf: templateURL)
        _ = try NemotronSuperPromptContract.verifiedTemplate(templateBytes)
        let checkpoint = stateDirectory.appendingPathComponent("synthetic-checkpoint", isDirectory: true)
        let source = try await phases.run("write_fixture") {
            try RunnerSyntheticFixture.writeCheckpoint(to: checkpoint)
        }
        let quote = try NemotronSuperInstallation.requiredLoadBytes(
            source: source, backendAllowanceBytes: settings.backendAllowanceBytes)
        log.emit("load.quote", ["load_quote_bytes": .bytes(quote),
            "pending_load_claim_bytes": .bytes(quote + settings.kvCapacityBytes)])
        let tokenizer = TokenizerHandle(RunnerSyntheticTokenizer())
        guard settings.kvCapacityBytes >= Int(UnifiedMemoryCap.minimumLoadKVBytes),
            let lease = await budget.claimPendingLoad(requestID: "nemotron-super-runner-load",
                weightBytes: UInt64(quote), minimumKVBytes: UInt64(settings.kvCapacityBytes))
        else { throw RunnerFailure.checkpoint("pending LOAD claim refused by the process budget") }
        let construction = NativeConstructionScope()
        let residency = try NemotronSuperResidency(capacityBytes: quote, maximumRequests: 1)
        var installed: NemotronSuperInstallation.Installed?
        var owner: NemotronSuperLocalBridgeBuilder.Owner?
        do {
            let built = try await phases.run("native_load") {
                let candidate = try NemotronSuperInstallation.stage(source: source, residency: residency,
                    dtype: .float32, backendAllowanceBytes: settings.backendAllowanceBytes,
                    construction: construction, makeModel: RunnerSyntheticFixture.model)
                installed = candidate
                try Task.checkCancellation()
                let built = try await NemotronSuperLocalBridgeBuilder.make(installed: candidate,
                    tokenizer: tokenizer, eosTokenIDs: RunnerSyntheticFixture.eosTokenIDs,
                    sizing: .init(weightsBytes: candidate.receipt.payloadBytes,
                        fp16KVBytesPerToken: settings.kvBytesPerTokenOverride
                            ?? RunnerSyntheticFixture.fp16KVBytesPerToken,
                        maxContextLength: settings.maxContextLength,
                        defaultMaxTokens: settings.defaultMaxTokens),
                    kvBytesCapacity: settings.kvCapacityBytes, kvBudget: budget, loadLease: lease,
                    construction: construction, environment: settings.engineEnvironment)
                owner = built
                try Task.checkCancellation()
                guard await budget.finishPendingLoad(lease) else {
                    throw RunnerFailure.checkpoint("pending LOAD lease lost before finish")
                }
                return built
            }
            let hook = try NemotronSuperLocalImageHTTP(owner: built, templateBytes: templateBytes)
            let identity: RunnerJSON = [
                "mode": "synthetic", "checkpoint_dir": .string(checkpoint.path),
                "index_sha256": .string(source.indexSHA256), "index_pinned": false,
                "template_sha256": .string(RunnerSyntheticFixture.sha256(templateBytes)),
                "payload_bytes": .bytes(installed?.receipt.payloadBytes ?? 0),
                "load_quote_bytes": .bytes(quote),
                "fp16_kv_bytes_per_token": .bytes(settings.kvBytesPerTokenOverride
                    ?? RunnerSyntheticFixture.fp16KVBytesPerToken),
                "eos_token_ids": .array(RunnerSyntheticFixture.eosTokenIDs.sorted().map { .bytes($0) }),
                "image_hook": true,
                "claim_scope": "synthetic weights and tokenizer; not a full-checkpoint result",
            ]
            return RunnerServing(bridge: built.bridge, tokenizer: tokenizer, imageHook: hook,
                identity: identity, retire: {
                    try await built.closeAfterDrain()
                    _ = residency.beginDrain()
                    return ["installation_residency_used_bytes": .bytes(residency.snapshot.usedBytes)]
                })
        } catch {
            await retireFailedLoad(construction: construction, owner: owner, installed: installed,
                residency: residency, lease: lease, budget: budget, log: log)
            throw error
        }
    }

    /// Mirrors NemotronSuperLocalLoad.retireFailedLoad: a retained native fault
    /// keeps every owner and charge; otherwise retire before refunding LOAD.
    private static func retireFailedLoad(construction: NativeConstructionScope,
        owner: NemotronSuperLocalBridgeBuilder.Owner?, installed: NemotronSuperInstallation.Installed?,
        residency: NemotronSuperResidency, lease: PendingModelLoadLease, budget: GlobalKVCacheBudget,
        log: RunnerEventLog) async {
        guard !construction.snapshot.isRetainedFault else {
            log.emit("load.retained_fault", ["reason": "construction scope retained a native fault"])
            return
        }
        if let owner {
            do { try await owner.closeAfterDrain() } catch {
                log.emit("load.retained_fault", ["reason": "owner retirement incomplete"])
                return
            }
        } else {
            installed?.closeAfterRetirement()
        }
        _ = residency.beginDrain()
        let finished = await budget.finishPendingLoad(lease)
        log.emit("load.failed_retired", ["lease_finished_now": .bool(finished),
            "installation_residency_used_bytes": .bytes(residency.snapshot.usedBytes)])
    }
}
