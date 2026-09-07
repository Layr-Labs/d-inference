import ProviderCore

extension ThroughputSweepReport {
    /// Prefill and decode use different harnesses. This scope describes only
    /// `prefill`; the selected/observed production backend describes `decode`.
    public struct PrefillExecution: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable {
            case modelNativeForward = "model_native_forward"
            case omitted
        }

        public let mode: Mode
        public let kvQuantization: String?
        public let reason: String?

        public static let nativeModelForward = PrefillExecution(
            mode: .modelNativeForward, kvQuantization: "native", reason: nil)
        public static let quantizedOmission = PrefillExecution(
            mode: .omitted, kvQuantization: nil,
            reason: "quantized_prefill_requires_scheduler_benchmark")
    }
}

extension ThroughputSweep {
    /// The legacy sweep prefill calls the model directly with its default
    /// native cache. Never invoke it as a quantized measurement; the production
    /// scheduler-prefill harness is the supported path for that experiment.
    static func measurePrefillForSelection(
        kvQuantization: EngineV2KVQuantizationSelection,
        measureNative: () async -> [ThroughputSweepReport.PrefillSample]
    ) async -> (samples: [ThroughputSweepReport.PrefillSample], execution: ThroughputSweepReport.PrefillExecution) {
        guard kvQuantization == .native else { return ([], .quantizedOmission) }
        return (await measureNative(), .nativeModelForward)
    }
}
