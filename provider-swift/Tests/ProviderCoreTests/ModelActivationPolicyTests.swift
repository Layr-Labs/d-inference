import Foundation
import Testing

@testable import ProviderCore

private let activationGiB: UInt64 = 1 << 30
private let measuredGPTOSSConfigSHA256 =
    "d1c1f73bf62116ed0bb37c068af80534543cd1de9b61d609fc01bf70920e842d"

private func measuredGPTOSSArchitecture(
    intermediateSize: Int = 2_880,
    layerTypes: [String]? = (0..<24).map {
        $0.isMultiple(of: 2) ? "sliding_attention" : "full_attention"
    }
) -> ModelArchitecture {
    ModelArchitecture(
        numLayers: 24,
        kvHeads: 8,
        headDim: 64,
        numKvSharedLayers: 0,
        globalHeadDim: nil,
        numGlobalKvHeads: nil,
        slidingWindowPattern: nil,
        layerTypes: layerTypes,
        maxContextLength: 131_072,
        numLocalExperts: 32,
        numExpertsPerTok: 4,
        hiddenSize: 2_880,
        intermediateSize: intermediateSize)
}

@Test func measuredGPTOSSProfileUsesMeasuredReserve() {
    let reserve = ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: measuredGPTOSSArchitecture(),
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: [:])

    #expect(reserve == 3 * activationGiB)
    #expect(reserve < UnifiedMemoryCap.defaultActivationReserveBytes)
}

@Test func lowerReserveRequiresExactMeasuredProfile() {
    let conservative = UnifiedMemoryCap.defaultActivationReserveBytes

    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: measuredGPTOSSArchitecture(),
        isVision: false,
        configSHA256: String(repeating: "0", count: 64),
        environment: [:]) == conservative)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "other",
        architecture: measuredGPTOSSArchitecture(),
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: [:]) == conservative)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: measuredGPTOSSArchitecture(intermediateSize: 2_881),
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: [:]) == conservative)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: measuredGPTOSSArchitecture(
            layerTypes: Array(repeating: "full_attention", count: 24)),
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: [:]) == conservative)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: measuredGPTOSSArchitecture(),
        isVision: true,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: [:]) == conservative)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: .empty,
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: [:]) == conservative)
}

@Test func activationOverrideCanRaiseButNotLowerMeasuredProfile() {
    let architecture = measuredGPTOSSArchitecture()

    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: architecture,
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "2"]) == 3 * activationGiB)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "gpt_oss",
        architecture: architecture,
        isVision: false,
        configSHA256: measuredGPTOSSConfigSHA256,
        environment: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "4"]) == 4 * activationGiB)
    #expect(ModelActivationPolicy.reserveBytes(
        modelType: "unknown",
        architecture: .empty,
        isVision: false,
        environment: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "4"])
        == UnifiedMemoryCap.defaultActivationReserveBytes)
}

@Test func fleetReserveUsesLargestResidentOrLoadingProfile() {
    let measured = 3 * activationGiB
    let conservative = UnifiedMemoryCap.defaultActivationReserveBytes

    #expect(ModelActivationPolicy.fleetReserveBytes([measured]) == measured)
    #expect(ModelActivationPolicy.fleetReserveBytes(
        [measured], including: conservative) == conservative)
    #expect(ModelActivationPolicy.fleetReserveBytes(
        [conservative], including: measured) == conservative)
}
