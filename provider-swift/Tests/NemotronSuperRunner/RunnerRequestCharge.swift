import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

/// What one request's fixed and per-token charges consist of, read from the
/// loaded owner's own engine and declarations (logical bytes before allocator
/// rounding unless named `projected`). Diagnostics only; nothing is allocated.
enum RunnerRequestCharge {
    /// `environment` and `contextTokens` are the load's: the serving policy's
    /// owner estimate (`policy_owner_bound`) is reported beside the engine's
    /// exact `owner` so a ready file shows whether the LOAD claim held it.
    static func json(bridge: EngineV2Bridge, environment: [String: String] = [:],
                     contextTokens: Int = NemotronSuperServingPolicy.contextTokens) async -> RunnerJSON {
        guard let engine = await bridge.ownedEngine as? EngineV2 else { return .null }
        var fields: [String: RunnerJSON] = [
            "engine_fixed_bytes": .bytes(engine.resolvedFixedBytesPerRequest),
            "bridge_fixed_bytes": .bytes(await bridge.fixedRequestBytes),
        ]
        let recurrent = (engine.loopForTesting.model as? any CBv2RecurrentSteppableModel)?
            .recurrentStateSpec
        if let bytes = try? recurrent?.fixedBytesPerRequest() {
            fields["recurrent_bytes_per_generation"] = .bytes(bytes)
        }
        if let policy = Memory.allocationFootprintPolicy(),
            let projected = try? recurrent?.allocationBytesPerGeneration(policy: policy)
        {
            fields["recurrent_projected_bytes_per_generation"] = .bytes(projected)
        }
        let assistant = engine.loopForTesting.mtp?.drafter as? NemotronSuperMTPAssistant
        if let language = assistant?.target, let charge = try? language.superDecodeCharge(kvElementBytes: 2) {
            let row = charge.rowWorkspace
            fields["decode_row"] = [
                "model_opt_layer": .bytes(row.modelOptLayerBytes), "output_head": .bytes(row.outputHeadBytes),
                "logits": .bytes(row.logitsBytes), "trunk": .bytes(row.trunkBytes),
                "backend_scratch": .bytes(row.backendScratchBytes), "total": .bytes(row.totalBytes),
            ]
        }
        guard case .bounded(let resolution)? = engine.resolvedMTPAdmission, let assistant
        else { return .object(fields) }
        let limits = resolution.limits
        fields["mtp_projected"] = [
            "resident": .bytes(resolution.residentBytes), "working": .bytes(resolution.workingBytes),
            "host": .bytes(resolution.hostBytes), "fixed": .bytes(resolution.fixedBytesPerRequest),
            "per_token": .bytes(resolution.auxiliaryBytesPerToken),
            "linear_slack": .bytes(resolution.auxiliaryLinearSlackBytes),
            "owner": .bytes(resolution.ownerBytes),
            "policy_owner_bound": .bytes(NemotronSuperServingPolicy.speculativeOwnerBoundBytes(
                requests: engine.loopForTesting.scheduler.config.maxConcurrentRequests,
                environment: environment, contextTokens: contextTokens)),
            "window_positions": .count(limits.maximumWindowPositions),
            "round_draft_steps": .count(limits.maximumRoundDraftSteps),
            "history_copies": .count(limits.maximumHistoryCopies),
        ]
        let workspace = assistant.workspace
        let graph = workspace.graph
        fields["mtp_window_workspace"] = [
            "graph_routed": .bytes(graph.routedArrayBytes), "graph_shared": .bytes(graph.sharedArrayBytes),
            "graph_attention": .bytes(graph.attentionArrayBytes), "graph_mixer": .bytes(graph.mixerArrayBytes),
            "history_chunk": .bytes(graph.historyChunkArrayBytes),
            "history_chunk_rows": .count(graph.historyChunkRows),
            "output_head": .bytes(workspace.outputHeadArrayBytes),
            "draft_append": .bytes(workspace.draftAppendBytes),
            "history_append": .bytes(workspace.historyAppendBytes),
            "backend_scratch": .bytes(workspace.backendScratchBytes),
            "draft_step": .bytes(workspace.draftStepBytes), "draft_depth": .count(workspace.draftDepth),
        ]
        if let spec = assistant.boundedRequestAllocation(limits: limits) {
            func list(_ buffers: [CBv2MTPFixedBufferSpec]) -> RunnerJSON {
                .array(buffers.map { ["bytes": .bytes($0.logicalBytes), "count": .count($0.allocationCount)] })
            }
            fields["mtp_fixed_declaration"] = [
                "resident": list(spec.resident), "working": list(spec.working), "host": .bytes(spec.hostBytes),
                "owner_working": list(spec.ownerWorking),
            ]
        }
        if let window = assistant.verifyWindowBytes(positions: limits.maximumWindowPositions) {
            fields["mtp_verify_window"] = .bytes(window)
        }
        if let specs = assistant.boundedRequestTokenAllocation(limits: limits) {
            fields["mtp_per_token_declaration"] = .array(specs.map {
                ["bytes_per_token": .bytes($0.bytesPerToken), "count": .count($0.allocationCount),
                 "granularity": .count($0.tokenGranularity), "padding": .count($0.tokenPadding)]
            })
        }
        return .object(fields)
    }
}
