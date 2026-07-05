import Foundation

extension BatchScheduler {
    func makeAdaptivePrefillRuntime(
        modelId: String,
        weightHash: String?,
        snapshot: LoadSnapshot
    ) -> AdaptivePrefillRuntime? {
        guard adaptivePrefillEnabled else { return nil }
        let quantScheme = Self.resolveKVQuantScheme(
            modelID: modelId,
            architecture: snapshot.architecture,
            kvQuantEnabled: kvQuantEnabled
        )
        let kvMode = quantScheme?.candidateMode.rawValue ?? "fp16"
        // The chip identity is part of the fingerprint so a different machine
        // (different roofline ⇒ different seed/optimum) keeps its own learned
        // rung rather than inheriting another chip's.
        let hardwareMemoryFingerprint = [
            "mem:\(ProcessInfo.processInfo.physicalMemory)",
            "chip:\(hardwareInfo?.chipName ?? "unknown")",
            "model-bytes:\(snapshot.bytes)",
            "ctx:\(snapshot.architecture.maxContextLength ?? 0)",
        ].joined(separator: "|")
        let key = AdaptivePrefillStoreKey(
            modelId: modelId,
            weightIdentity: weightHash ?? "bytes:\(snapshot.bytes)",
            kvMode: kvMode,
            hardwareMemoryFingerprint: hardwareMemoryFingerprint,
            policyIdentity: AdaptivePrefillPolicy.algorithmIdentity
        )
        return AdaptivePrefillRuntime(policy: adaptivePrefillPolicy(snapshot: snapshot), key: key)
    }

    /// Seed the chunk ladder from the GPU roofline + model architecture. Unknown
    /// hardware (no peak-FLOPS entry) falls back to the generic empirical ladder.
    private func adaptivePrefillPolicy(snapshot: LoadSnapshot) -> AdaptivePrefillPolicy {
        guard let hardwareInfo else { return .liveDefault() }
        return AdaptivePrefillSeed.policy(hardware: hardwareInfo, model: snapshot.architecture)
    }
}
