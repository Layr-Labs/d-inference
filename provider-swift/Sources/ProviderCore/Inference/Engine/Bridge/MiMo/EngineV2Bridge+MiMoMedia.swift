import MLXLMCommon
import MLXVLM

extension EngineV2Bridge {
    /// Classification only: the engine still checks the seal's generation,
    /// ownership and one-shot use before accepting work. A failed submission
    /// cannot emit a completed-prefill receipt.
    func nativeMediaMeasurementEligible(_ media: CBv2MultimodalInput?) -> Bool {
        guard let media, media.nativeMediaToken != nil, media.attention == .causal,
              media.positionState == nil, media.deepstackEmbeddings == nil else { return false }
        return (try? nativeMiMoDecodedMediaBinding()) != nil
    }

    /// Real published owner only. A request/model-name string or isVLM bit
    /// cannot manufacture this opt-in profile. No raw model/asset is exported.
    func nativeMiMoDecodedMediaBinding() throws
        -> (load: MiMoV26ServingLoad, sampling: MiMoV26EncodedVisualDecoder.Sampling, defaultMaxTokens: Int) {
        guard canSubmitWithNativeOwner(), let transaction = nativeTransaction,
              nativeTransactionID == transaction.id else {
            throw MiMoV26ServingLoadError.managedLoadRequired
        }
        let binding = try transaction.decodedMediaBinding(expectedBridge:self)
        return (binding.load,binding.sampling,defaultMaxTokens)
    }
    /// Actual issued decoded-PCM profile only; receipt metadata never creates
    /// a codec/profile and the registered bridge cannot be substituted.
    func nativeMiMoDecodedAudioBinding() throws
        -> (load: MiMoV26ServingLoad, receipt: MiMoV26AudioSidecarLoadReceipt, defaultMaxTokens: Int) {
        guard canSubmitWithNativeOwner(), let transaction = nativeTransaction,
              nativeTransactionID == transaction.id else {
            throw MiMoV26ServingLoadError.managedLoadRequired
        }
        let binding = try transaction.decodedAudioBinding(expectedBridge: self)
        return (binding.load, binding.receipt, defaultMaxTokens)
    }
}
