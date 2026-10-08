import Foundation
@_spi(ClusterBenchmark) import MLXLLM

/// Benchmark selection only. Source identity and memory admission remain owned
/// by the sealed registered definition and the existing full-reference loader.
struct QwenResidentSoloModelScope {
    let model: QwenRegisteredDenseModel
    let referenceCut: Int
    let gatedDeltaLayers: Int
    let warmupProfile: QwenGatedDeltaWarmupProfile

    init(definition: QwenResidentModelDefinition) throws {
        let geometry = try definition.specification.expectedGeometry()
        model = definition.specification.model
        switch model {
        case .qwen35NineB:
            referenceCut = 4
            warmupProfile = .nineB
        case .qwen38TwentySevenB:
            referenceCut = 16
            warmupProfile = .twentySevenB
        }
        guard definition.supportedCuts.contains(referenceCut),
              geometry.linearKeyHeads == 16,
              geometry.linearValueHeads == warmupProfile.valueHeads,
              geometry.linearKeyDimension == 128,
              geometry.linearValueDimension == 128 else {
            throw ProbeError("Solo warmup scope differs from registered geometry")
        }
        gatedDeltaLayers = geometry.layers - geometry.layers / geometry.fullAttentionInterval
    }

    func requireWarmup(gatedDeltaLayers actualLayers: Int, fusedLayers: Int, queryBlock: Int,
                       nativePrefillCalls: Int, nativeDecodeCalls: Int,
                       fallbackCalls: Int, invalidGeometryCalls: Int) throws {
        guard actualLayers == gatedDeltaLayers, fusedLayers == gatedDeltaLayers,
              queryBlock == 128, nativePrefillCalls == gatedDeltaLayers * 16,
              nativeDecodeCalls == gatedDeltaLayers * 127,
              fallbackCalls == 0, invalidGeometryCalls == 0 else {
            throw ProbeError("Solo warmup did not establish the required native GDN/fusion/query-block eligibility")
        }
    }
}
