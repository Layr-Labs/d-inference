import MLXLMCommon
import XCTest

@testable import ProviderCore

final class EngineV2NativeBlockTimingTests: XCTestCase {
    func testFirstCanvasIsIncludedAndPrefillIsSeparated() {
        var timing = CBv2RequestTiming()
        timing.prefillFirstLaunchNanos = 100_000_000
        timing.promptComputedNanos = 600_000_000
        timing.firstTokenNanos = 5_599_999_000
        timing.finishedNanos = 5_600_000_000
        XCTAssertEqual(EngineV2NativeBlockTiming.prefillSeconds(timing), 0.5)
        // A 100-token burst one microsecond before finish is 20tok/s over
        // its five seconds of actual generation, not 100 million tok/s.
        XCTAssertEqual(EngineV2NativeBlockTiming.generationRate(completionTokens: 100, timing: timing), 20)
    }

    func testMissingOrReversedClocksCannotCreateASpeedClaim() {
        var timing = CBv2RequestTiming()
        XCTAssertNil(EngineV2NativeBlockTiming.generationRate(completionTokens: 100, timing: timing))
        XCTAssertNil(EngineV2NativeBlockTiming.prefillSeconds(timing))
        timing.prefillFirstLaunchNanos = 20
        timing.promptComputedNanos = 10
        timing.finishedNanos = 5
        XCTAssertNil(EngineV2NativeBlockTiming.generationRate(completionTokens: 100, timing: timing))
        XCTAssertNil(EngineV2NativeBlockTiming.prefillSeconds(timing))
    }
}
