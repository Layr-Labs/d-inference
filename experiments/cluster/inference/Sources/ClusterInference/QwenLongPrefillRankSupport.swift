import Foundation

func requireQwenLongPrefillRankIdentity(_ identity: QwenLayerStageSessionIdentity,
    agreement: QwenLayerStageProfiledPrefillStartAgreement, rank: Int) throws {
    let d = agreement.descriptor
    let expected = QwenLayerStageSessionIdentity(stageIndex: rank, requestFingerprint: d.requestFingerprint,
        artifactAggregateSHA256: d.artifactAggregateSHA256, storageCommitmentSHA256: d.storageCommitmentSHA256,
        bf16ConversionEnabled: d.bf16ConversionEnabled, sourceConfigurationSHA256: d.sourceConfigurationSHA256,
        constructionConfigurationSHA256: rank == 0 ? d.producerConstructionConfigurationSHA256 : d.consumerConstructionConfigurationSHA256,
        planFingerprint: d.planFingerprint, stageFingerprint: rank == 0 ? d.producerStageFingerprint : d.consumerStageFingerprint,
        activationDType: d.nativeDType)
    guard identity == expected else {
        throw ProbeError("Fresh long context differs from the pre-clock admitted source and rank")
    }
}

func qwenLongPrefillRankTiming(start: UInt64, stop: UInt64, closed: UInt64) throws -> QwenLongPrefillRankTiming {
    guard stop > start, closed >= stop else { throw ProbeError("Long prefill clock did not advance monotonically") }
    let elapsed = stop - start
    let rate = 8192.0 * 1e9 / Double(elapsed)
    guard rate.isFinite, rate > 0 else { throw ProbeError("Long prefill diagnostic clock arithmetic is nonfinite") }
    return .init(startUptimeNanoseconds: start, stopUptimeNanoseconds: stop, elapsedNanoseconds: elapsed,
        promptTokensPerFirstTokenSecond: rate, postStopThroughRequestCloseNanoseconds: closed - stop)
}
