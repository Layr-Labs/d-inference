import Foundation
import Testing
@testable import ProviderBenchmark
import ProviderCore

@Suite("Sweep prefill numerical scope")
struct ThroughputSweepPrefillScopeTests {
    @Test(arguments: [EngineV2KVQuantizationSelection.int4, .k8v4, .int8])
    func quantizedSweepDoesNotRunTheNativePrefillClosure(selection: EngineV2KVQuantizationSelection) async throws {
        var nativeCalls = 0
        let outcome = await ThroughputSweep.measurePrefillForSelection(kvQuantization: selection) {
            nativeCalls += 1
            return [.init(promptTokens: 128, prefillTokensPerSecond: 1000, elapsedMs: 128)]
        }
        #expect(nativeCalls == 0)
        #expect(outcome.samples.isEmpty)
        #expect(outcome.execution == .quantizedOmission)
        let json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(outcome.execution)) as? [String: Any])
        #expect(json["mode"] as? String == "omitted")
        #expect(json["reason"] as? String == "quantized_prefill_requires_scheduler_benchmark")
        #expect(json["kvQuantization"] == nil) // no format was measured
    }

    @Test func nativeControlRetainsMeasurementsAndNamesItsActualScope() async throws {
        var nativeCalls = 0
        let outcome = await ThroughputSweep.measurePrefillForSelection(kvQuantization: .native) {
            nativeCalls += 1
            return [.init(promptTokens: 128, prefillTokensPerSecond: 1000, elapsedMs: 128)]
        }
        #expect(nativeCalls == 1)
        #expect(outcome.samples.count == 1)
        #expect(outcome.samples.first?.promptTokens == 128)
        #expect(outcome.execution.mode == .modelNativeForward)
        #expect(outcome.execution.kvQuantization == "native")
        #expect(outcome.execution.reason == nil)
    }
}
