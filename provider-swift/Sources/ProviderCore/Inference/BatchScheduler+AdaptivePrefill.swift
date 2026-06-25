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
        let hardwareMemoryFingerprint = [
            "mem:\(ProcessInfo.processInfo.physicalMemory)",
            "model-bytes:\(snapshot.bytes)",
            "ctx:\(snapshot.architecture.maxContextLength ?? 0)",
        ].joined(separator: "|")
        let key = AdaptivePrefillStoreKey(
            modelId: modelId,
            weightIdentity: weightHash ?? "bytes:\(snapshot.bytes)",
            kvMode: kvMode,
            hardwareMemoryFingerprint: hardwareMemoryFingerprint
        )
        return AdaptivePrefillRuntime(key: key)
    }
}
