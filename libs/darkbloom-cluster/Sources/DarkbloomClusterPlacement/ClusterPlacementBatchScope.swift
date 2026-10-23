import DarkbloomClusterProtocol
import Foundation

/// A bounded set of independent histories. Pipeline quotes retain the
/// registered family's whole-model state on every rank; exact Qwen27 may
/// additionally supply its complete native TP ledger. Neither quote is READY
/// capacity or free-memory credit. Shared weights and load headroom remain.
public struct ClusterPlacementBatchScope: Equatable, Sendable {
    public let request: ClusterPlacementRequestScope
    public let lanes: Int
    public let requestChargeEveryRankBytes: Int
    public let chunkTokens: Int?
    public let sharedWorkspaceEveryRankBytes: Int
    public let tensorParallelQuote: ClusterPlacementTensorBatchQuote?
    public var supportedModes: [ClusterGenerationMode] {
        tensorParallelQuote == nil ? [.pipeline] : [.pipeline, .tensorParallel]
    }

    public init(request: ClusterPlacementRequestScope, lanes: Int,
                tensorParallelQuote: ClusterPlacementTensorBatchQuote? = nil) throws {
        try request.validate()
        guard [2, 4, 8].contains(lanes), request.requestChargeEveryRankBytes > 0,
              let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: request.runtimeModelID),
              Self.adapters.contains(adapter) else {
            throw ClusterPlacementError("This model has no priced native pipeline batch scope")
        }
        let charge = request.requestChargeEveryRankBytes.multipliedReportingOverflow(by: lanes)
        guard !charge.overflow, charge.partialValue <= ClusterWorkerLimits.capacityBytes else {
            throw ClusterPlacementError("The concurrent request state exceeds the placement byte bound")
        }
        if let tensorParallelQuote {
            try tensorParallelQuote.validate()
            guard tensorParallelQuote.request == request, tensorParallelQuote.lanes == lanes else {
                throw ClusterPlacementError("Tensor and pipeline batch quotes describe different requests or widths")
            }
        }
        self.tensorParallelQuote = tensorParallelQuote
        self.request = request; self.lanes = lanes
        chunkTokens = tensorParallelQuote?.chunkTokens; sharedWorkspaceEveryRankBytes = 0
        requestChargeEveryRankBytes = charge.partialValue
    }

    public init(quote: ClusterPlacementBatchQuote) throws {
        try quote.validate()
        tensorParallelQuote = nil
        request = quote.request; lanes = quote.lanes; chunkTokens = quote.chunkTokens
        sharedWorkspaceEveryRankBytes = quote.sharedWorkspaceEveryRankBytes
        requestChargeEveryRankBytes = try quote.totalEveryRankBytes()
    }

    /// A future stage adapter must supply a conservative full-state quotation
    /// before it joins this policy. GLM's exact quotation path is separate.
    private static let adapters: Set<ClusterRuntimeAdapter> = [
        .qwen35Dense, .qwen35RoutedExperts, .qwen35PrismHadamard, .nemotronH, .gemma4LayerStage,
    ]

    /// A singleton keeps its existing mode choice. Real concurrent pressure
    /// considers the largest bounded native width first to avoid repeated
    /// reloads as a burst grows. Every offered width carries the full listener
    /// profile and is separately priced again after both old owners release.
    public static func candidateWidths(waitingRequests: Int) -> [Int] {
        guard waitingRequests > 1 else { return [] }
        return [8, 4, 2]
    }

    /// A native workspace quote may not be replayed after chunk derivation or
    /// a configuration edit. Legacy whole-model scopes carry no chunk binding.
    public func requireChunk(_ value: Int, derived: Bool) throws {
        guard chunkTokens.map({ !derived && $0 == value }) ?? true else {
            throw ClusterPlacementError("Native batch placement must preserve its quoted original chunk")
        }
    }

    public func apply(to policy: inout ClusterPlacementPolicy, layout: ClusterModelLayout) throws {
        // Refuse explicit incompatible choices instead of changing what a
        // caller asked to execute. TP is considered only with its native quote.
        guard policy.modes.map({ !$0.isEmpty && $0.allSatisfy(supportedModes.contains) }) ?? true,
              policy.schedules == nil || policy.schedules == [.serial],
              policy.forcedMode == nil, !policy.handOffModes else {
            throw ClusterPlacementError("Concurrent placement requires a serial-prefill plain pipeline")
        }
        try request.apply(to: &policy, layout: layout)
        // The ordinary planner takes max(whole-rank quote, owned-layer state).
        // Multiplying just a smaller quote would underprice a wider owned range.
        // Check the full-model layer lower bound before charging every lane.
        let context = request.promptTokens + request.outputTokens
        var layerState = 0
        for layer in layout.layers {
            let variable = layer.stateBytesPerToken.multipliedReportingOverflow(by: context)
            let state = variable.partialValue.addingReportingOverflow(layer.stateFixedBytes)
            let total = layerState.addingReportingOverflow(state.partialValue)
            guard !variable.overflow, !state.overflow, !total.overflow, total.partialValue >= 0 else {
                throw ClusterPlacementError("Concurrent layer state overflowed its byte bound")
            }
            layerState = total.partialValue
        }
        guard request.requestChargeEveryRankBytes >= layerState else {
            throw ClusterPlacementError("The batch scope does not cover every layer's request state")
        }
        if let tensorParallelQuote { try tensorParallelQuote.validate(layout: layout) }
        policy.modes = policy.modes ?? supportedModes; policy.schedules = [.serial]
        policy.tensorParallelBatchQuote = tensorParallelQuote
        policy.requestChargeEveryRankBytes = requestChargeEveryRankBytes
        // Singleton TP/MTP preference must not leak into this distinct batch
        // recommendation. Its predictions remain single-request stage rates;
        // multiplying them by the width would invent a measured batch speed.
        policy.keptMode = nil; policy.keptModeReason = nil
    }
}
