import XCTest
import MLXLMCommon
@testable import ProviderCore

final class MiMoV26PrefillProcessControlTests: XCTestCase {
    func testNativeFactoryBoundaryAcceptsInheritedAndMatchingLatches() throws {
        try EngineV2Factory.validateNativeMiMoPrefillPolicy(environment: [:])
        XCTAssertEqual(EngineV2Factory.nativeMiMoAutomaticPrefill(environment: [:]),
            MiMoV26PrefillPolicy.latchedAttentionEnabled && MiMoV26PrefillPolicy.latchedGroupingEnabled)
        try EngineV2Factory.validateNativeMiMoPrefillPolicy(environment: [
            MiMoV26PrefillPolicy.attentionEnvironmentKey:
                MiMoV26PrefillPolicy.latchedAttentionEnabled ? "1" : "0",
            MiMoV26PrefillPolicy.groupedEnvironmentKey:
                MiMoV26PrefillPolicy.latchedGroupingEnabled ? "1" : "0"])
    }

    func testNativeFactoryBoundaryRejectsContradictionsBeforeEncoding() {
        let attentionBefore = MiMoV26NAXAttention.encodedCalls()
        let groupedBefore = MiMoV26BlockBatchAttention.encodedDispatches()
        for (key, actual) in [
            (MiMoV26PrefillPolicy.attentionEnvironmentKey, MiMoV26PrefillPolicy.latchedAttentionEnabled),
            (MiMoV26PrefillPolicy.groupedEnvironmentKey, MiMoV26PrefillPolicy.latchedGroupingEnabled)] {
            // With the normal unset/default-on process this reproduces both
            // injected0 and malformed rollbacks. Startup0 also tests reverse-on.
            let conflictingValues = actual ? ["0", "malformed"] : ["1", "on"]
            for value in conflictingValues {
                XCTAssertThrowsError(try EngineV2Factory.validateNativeMiMoPrefillPolicy(
                    environment: [key: value])) { error in
                    XCTAssertEqual(error as? MiMoV26PrefillPolicy.ProcessControlMismatch,
                        .incompatible(environmentKey: key, requested: !actual, latched: actual))
                }
            }
        }
        XCTAssertEqual(MiMoV26NAXAttention.encodedCalls(), attentionBefore)
        XCTAssertEqual(MiMoV26BlockBatchAttention.encodedDispatches(), groupedBefore)
    }
}
