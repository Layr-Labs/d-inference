import MLXLMCommon
import ProviderCore

/// Actual cumulative decisions from one measured engine, captured after its
/// shutdown returns. A graph-built route is not a finalized GPU kernel count.
public struct BenchmarkQuantizedPrefillReceipt: Codable, Sendable {
    public let counterScope: String
    public let observationScope: String
    public let successfulTerminalControls: Bool
    public let statistics: PagedQuantizedPrefillStatistics

    enum Failure: Error { case incompatibleSelection, unavailableStatistics, inconsistentStatistics }

    static func validateSelection(
        quantization: EngineV2KVQuantizationSelection, mode: PagedQuantizedPrefillMode
    ) throws {
        guard quantization != .native || mode == .direct else { throw Failure.incompatibleSelection }
    }

    static func capture(
        engine: any CBv2Engine, quantization: EngineV2KVQuantizationSelection,
        mode: PagedQuantizedPrefillMode, successfulTerminalControls: Bool
    ) throws -> Self? {
        try validateSelection(quantization: quantization, mode: mode)
        guard quantization != .native else { return nil }
        guard let statistics = (engine as? EngineV2)?.quantizedPrefillStatisticsSnapshot() else {
            throw Failure.unavailableStatistics
        }
        return try make(statistics: statistics, expectedMode: mode,
                        successfulTerminalControls: successfulTerminalControls)
    }

    static func make(statistics: PagedQuantizedPrefillStatistics,
                     expectedMode: PagedQuantizedPrefillMode,
                     successfulTerminalControls: Bool) throws -> Self {
        guard statistics.mode == expectedMode, statistics.currentAdditionalWorkspaceBytes >= 0,
              !successfulTerminalControls || statistics.currentAdditionalWorkspaceBytes == 0,
              [statistics.directCallCount, statistics.fusedCallCount,
               statistics.directQueryTokenCount, statistics.fusedQueryTokenCount,
               statistics.budgetFallbackCount, statistics.ineligibleFallbackCount,
               statistics.peakAdditionalWorkspaceBytes].allSatisfy({ $0 >= 0 }) else {
            throw Failure.inconsistentStatistics
        }
        return .init(counterScope: "graph_built_layer_rows",
                     observationScope: "measured_engine_after_shutdown",
                     successfulTerminalControls: successfulTerminalControls, statistics: statistics)
    }
}
