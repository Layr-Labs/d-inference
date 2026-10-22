import Foundation
import MLX
@_spi(ExpertParallel) import MLXLMCommon

/// Correctness-first route boundary using actual CPU readback, never a claimed
/// device-only dispatch or throughput result. No request/cache/device ownership.
/// Caller must charge the complete <=128-token graph + host packet envelope and
/// retain the exchange through the original session's retirement/cleanup.
final class Gemma4ExpertCollectiveOperation: Gemma4ExpertForwardOperation {
    let partition: Gemma4ExpertPartition
    let binding: Gemma4ExpertInvocationBinding
    private let exchange: any Gemma4ExpertUnweightedExchange
    private let temporaryPolicy: Gemma4ExpertTemporaryPolicy?
    private var temporaryWindow: Gemma4ExpertTemporaryWindow?

    init(partition: Gemma4ExpertPartition, binding: Gemma4ExpertInvocationBinding,
         exchange: any Gemma4ExpertUnweightedExchange,
         temporaryPolicy: Gemma4ExpertTemporaryPolicy? = nil) throws {
        try binding.validate(partition: partition)
        if temporaryPolicy != nil, !(exchange is Gemma4ExpertWire) {
            throw ProbeError("Gemma adjacent temporary policy requires the original completed Collective wire")
        }
        self.partition = partition; self.binding = binding; self.exchange = exchange
        self.temporaryPolicy = temporaryPolicy
        temporaryWindow = try temporaryPolicy.map { _ in
            try Gemma4ExpertTemporaryWindow(frames: binding.purpose == .probe ? 2 : 3)
        }
    }

    func unweighted(frame: QwenLayerStageFrame, layer: Int, input: MLXArray,
                    globalIDs: MLXArray, weights: MLXArray, bank: SwitchGLU,
                    check: () throws -> Void) throws -> MLXArray {
        do {
            if temporaryPolicy == nil {
                return try unweightedScoped(frame: frame, layer: layer, input: input,
                    globalIDs: globalIDs, weights: weights, bank: bank, check: check)
            }
            // Drain completed backend/Objective-C temporaries at the existing
            // borrowed hook boundary. Returned graph ownership escapes normally.
            return try autoreleasepool {
                try unweightedScoped(frame: frame, layer: layer, input: input,
                    globalIDs: globalIDs, weights: weights, bank: bank, check: check)
            }
        } catch { temporaryWindow?.poison(); throw error }
    }

    func requireTemporaryWindowComplete() throws { try temporaryWindow?.requireComplete() }

    private func unweightedScoped(frame: QwenLayerStageFrame, layer: Int, input: MLXArray,
                                  globalIDs: MLXArray, weights: MLXArray, bank: SwitchGLU,
                                  check: () throws -> Void) throws -> MLXArray {
        try check()
        guard (0..<30).contains(layer), input.ndim == 2,
              (1...128).contains(input.dim(0)), input.dim(1) == 2816,
              input.dtype == .bfloat16, globalIDs.shape == [input.dim(0), 8],
              globalIDs.dtype == .uint32, weights.shape == globalIDs.shape,
              weights.dtype == input.dtype, !bank.hasFusedGateUp,
              (1...128).contains(frame.tokenCount),
              (input.dim(0) == frame.tokenCount || (layer == 29 && frame.phase == .prefill
                && input.dim(0) < frame.tokenCount)) else {
            throw ProbeError("Gemma EP actual decoder/router geometry exceeds its explicit envelope")
        }
        if let temporaryPolicy {
            guard input.dim(0) <= temporaryPolicy.maximumFrameTokens,
                  frame.tokenCount <= temporaryPolicy.maximumFrameTokens else {
                throw ProbeError("Gemma adjacent temporary path exceeded its closed frame bound")
            }
            try temporaryWindow?.begin(frame: frame.sequence, layer: layer)
        }
        // The existing owner's MLX fault/deadline check is passed through every
        // eval/read/transport boundary. Native errors retain outer precedence.
        eval(input, globalIDs, weights); try check()
        try temporaryWindow?.inputEvaluated()
        let flat = globalIDs.asArray(UInt32.self); try check()
        let selected = (0..<input.dim(0)).map { row in
            (0..<8).map { Int(flat[row * 8 + $0]) }
        }
        let ownership = try partition.ownership()
        // Reuse the exact pure map and kernel policy. Unlike the standalone
        // prepared primitive, do not create a second copy of global router IDs
        // or unused peer index tensors: the real router arrays already exist.
        let plan = try ExpertDispatchPlan(ownership: ownership, selectedGlobalIDs: selected,
            maxAssignments: ExpertAxisQualificationLimits.maximumAssignments)
        let policies = try (0..<2).map { rank in
            try ExpertAxisProjectionPolicy(globalAssignments: plan.assignmentCount,
                globalExperts: 128, ownedExperts: partition.globalIDsByRank[rank].count,
                localAssignments: plan.assignmentCountsByRank[rank])
        }
        let policy = policies[partition.rank]
        let assignments = plan.assignmentsByRank[partition.rank]
        let padded = try policy.padded(assignments)
        let local: MLXArray?
        if padded.isEmpty { local = nil }
        else {
            let rows = MLXArray(padded.map { UInt32($0.tokenIndex) })
            let ids = MLXArray(padded.map { UInt32($0.localExpertID) }).reshaped(padded.count, 1)
            eval(rows, ids); try check()
            let output = bank.callAsPartition(input.take(rows, axis: 0), ids,
                sortAssignments: policy.sortAssignments, sortedProjection: policy.sortedProjection)
                .reshaped(padded.count, 2816)
            local = policy.paddedAssignments == 0 ? output : output[..<assignments.count, 0...]
        }
        if let local { eval(local); try check() }
        let inputSHA = sha256(input.asData(access: .copy).data); try check()
        let weightsSHA = sha256(weights.asData(access: .copy).data); try check()
        let scope = Gemma4ExpertLayerScope(binding: binding, frame: frame, globalLayer: layer,
            tokenCount: input.dim(0), dtype: String(describing: input.dtype),
            routeSHA256: sha256(try canonicalJSONData(selected)), inputSHA256: inputSHA,
            weightsSHA256: weightsSHA, assignmentCounts: plan.assignmentCountsByRank,
            projectionPolicies: policies)
        // Keep local storage through actual consumed ACK, as required by the
        // existing completed-send + strict frame protocol. No fire-and-forget.
        let peer = try withExtendedLifetime(local) {
            try exchange.exchange(scope: scope, localRank: partition.rank, localRows: local, check: check)
        }
        try check()
        guard peer.scope == scope, peer.producerRank == 1 - partition.rank else {
            throw ProbeError("Gemma EP peer frame/route/input/weight/ownership identity differs")
        }
        var byRank: [MLXArray?] = [nil, nil]
        byRank[partition.rank] = local; byRank[peer.producerRank] = peer.array
        for rank in 0..<2 {
            let count = plan.assignmentCountsByRank[rank]
            if count == 0 {
                guard case .none = byRank[rank] else { throw ProbeError("Gemma EP empty rank returned rows") }
            } else {
                guard let value = byRank[rank], value.shape == [count, 2816], value.dtype == input.dtype else {
                    throw ProbeError("Gemma EP returned rows contain padding or wrong shape/type")
                }
            }
        }
        // The concrete Wire returned only after existing CPU/GPU completion
        // fences and consumed ACKs. No extra synchronization is introduced.
        try temporaryWindow?.exchangeCompleted()
        let order = MLXArray(try plan.reassemblyIndices(
            returnedByRank: plan.assignmentsByRank).map(UInt32.init))
        eval(order); try check()
        let outputs = byRank.compactMap { $0 }
        guard !outputs.isEmpty else { throw ProbeError("Gemma EP has no assignment outputs") }
        let joined = outputs.count == 1 ? outputs[0] : concatenated(outputs, axis: 0)
        let result = joined.take(order, axis: 0).reshaped(input.dim(0), 8, 2816)
        try temporaryWindow?.returned()
        return result
    }
}
