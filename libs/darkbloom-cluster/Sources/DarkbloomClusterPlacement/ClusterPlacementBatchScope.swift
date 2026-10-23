import DarkbloomClusterProtocol
import Foundation

/// A bounded set of independent histories for a plain pipeline. The quote is
/// the registered family's whole-model state on every rank, not its READY
/// capacity or a share of currently free memory. Shared weights, serial
/// prefill workspace and load headroom keep the ordinary planner's accounting.
public struct ClusterPlacementBatchScope: Equatable, Sendable {
    public let request: ClusterPlacementRequestScope
    public let lanes: Int
    public let requestChargeEveryRankBytes: Int
    public let chunkTokens: Int?
    public let sharedWorkspaceEveryRankBytes: Int

    public init(request: ClusterPlacementRequestScope, lanes: Int) throws {
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
        self.request = request; self.lanes = lanes
        chunkTokens = nil; sharedWorkspaceEveryRankBytes = 0
        requestChargeEveryRankBytes = charge.partialValue
    }

    public init(quote: ClusterPlacementBatchQuote) throws {
        try quote.validate()
        request = quote.request; lanes = quote.lanes; chunkTokens = quote.chunkTokens
        sharedWorkspaceEveryRankBytes = quote.sharedWorkspaceEveryRankBytes
        requestChargeEveryRankBytes = try quote.totalEveryRankBytes()
    }

    /// A future stage adapter must supply a conservative full-state quotation
    /// before it joins this policy. GLM's exact quotation path is separate.
    private static let adapters: Set<ClusterRuntimeAdapter> = [
        .qwen35Dense, .qwen35RoutedExperts, .qwen35PrismHadamard, .nemotronH, .gemma4LayerStage,
    ]

    /// A singleton keeps its existing mode choice. Larger demand is rounded
    /// up to a bounded native width; every offered width is still separately
    /// priced against both ranks after the old owner releases its memory.
    public static func candidateWidths(waitingRequests: Int) -> [Int] {
        guard waitingRequests > 1 else { return [] }
        let ceiling = waitingRequests <= 2 ? 2 : waitingRequests <= 4 ? 4 : 8
        return [8, 4, 2].filter { $0 <= ceiling }
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
        // caller asked to execute. An unspecified mode becomes plain pipeline.
        guard policy.modes == nil || policy.modes == [.pipeline],
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
        policy.modes = [.pipeline]; policy.schedules = [.serial]
        policy.requestChargeEveryRankBytes = requestChargeEveryRankBytes
        // Singleton TP/MTP preference must not leak into this distinct batch
        // recommendation. Its predictions remain single-request stage rates;
        // multiplying them by the width would invent a measured batch speed.
        policy.keptMode = nil; policy.keptModeReason = nil
    }
}
