import Foundation
import MLXLMCommon
import XCTest
@testable import ProviderCore

/// A native MiMo engine that trips the SDK's step watchdog is sealed for good
/// (`fail(.stepWatchdog)` is write-once, so `engineStep` never runs again). A slow
/// but healthy step must therefore never reach it. On an M5 Ultra a MiMo prefill
/// step at about 130k tokens of context already takes 11.8 s, and production M3
/// Ultras prefill MiMo three to four times slower.
final class MiMoV26StepWatchdogTests: XCTestCase {
    func testANativeMiMoStepMayRunAsLongAsThePrefillProgressLease() {
        let sdk = CBv2EngineLoopConfig()
        let native = EngineV2Factory.nativeMiMoLoopConfig(environment: [:])
        XCTAssertEqual(sdk.stepTimeout, 30, "the SDK default this override exists for")
        XCTAssertEqual(native.stepTimeout, 120)
        XCTAssertGreaterThanOrEqual(native.stepTimeout, sdk.prefillProgressLease,
            "a step the prefill progress lease still accepts must not seal the engine")
    }

    func testEverythingElseKeepsTheSDKDefaults() {
        let sdk = CBv2EngineLoopConfig()
        let native = EngineV2Factory.nativeMiMoLoopConfig(environment: [:])
        XCTAssertEqual(native.watchdogInterval, sdk.watchdogInterval)
        XCTAssertEqual(native.requestTimeout, sdk.requestTimeout)
        XCTAssertFalse(native.useLegacyRequestTimeout)
        XCTAssertEqual(native.admissionLease, sdk.admissionLease)
        XCTAssertEqual(native.prefillProgressLease, sdk.prefillProgressLease)
        XCTAssertEqual(native.decodeProgressLease, sdk.decodeProgressLease)
        XCTAssertEqual(native.backpressureLease, sdk.backpressureLease)
        XCTAssertEqual(native.safetyCeilingDecodeFloorTPS, sdk.safetyCeilingDecodeFloorTPS)
        XCTAssertEqual(native.eventBufferCapacity, sdk.eventBufferCapacity)
        XCTAssertEqual(native.shutdownTimeout, sdk.shutdownTimeout)
        XCTAssertEqual(native.idleRecheckInterval, sdk.idleRecheckInterval)
    }

    func testTheLegacyRequestTimeoutRollbackStillApplies() {
        let legacy = EngineV2Factory.nativeMiMoLoopConfig(
            environment: [EngineV2Factory.legacyRequestTimeoutEnvKey: "1"])
        XCTAssertTrue(legacy.useLegacyRequestTimeout)
        XCTAssertEqual(legacy.stepTimeout, EngineV2Factory.nativeMiMoLoopConfig(environment: [:]).stepTimeout)
    }

    /// The engine keeps its loop settings private, and a native MiMo engine needs
    /// the real weights, so the wiring is checked in the factory's source: every
    /// native-tracked engine it builds takes the native MiMo loop settings.
    func testEveryNativeMiMoEngineTakesTheNativeLoopSettings() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+Native.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        func count(_ needle: String) -> Int { source.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(count("nativeCompletionTracking: true"), 2, "the contiguous and the paged native MiMo engine")
        XCTAssertEqual(count("loopConfig: EngineV2Factory.nativeMiMoLoopConfig()"), 2)
        XCTAssertEqual(count("loopConfig:"), 2, "no native MiMo engine may fall back to the SDK's 30 s watchdog")
    }
}
