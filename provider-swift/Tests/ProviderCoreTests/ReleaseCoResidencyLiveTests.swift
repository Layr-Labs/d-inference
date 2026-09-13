import Foundation
import Testing
@testable import ProviderCore

@Suite("0.9 exact three-slot co-residency (opt-in live)", .serialized)
struct ReleaseCoResidencyLiveTests {
    @Test("Q36 streams during GPT/QAT loads; real shrink, cancellation, drain and regrow",
          .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_RELEASE_CORESIDENCY_CONFIG"] != nil))
    func exactReleaseLifecycle() async throws {
        let (fixture, digest) = try ReleaseCoResidencyFixture.read()
        try fixture.verifyModels()
        try ReleaseCoResidencyFixture.require(bindRuntimeMetallibForMLX(
            from: URL(fileURLWithPath: fixture.metallibPath)) == fixture.metallibSHA256,
            "reviewed runtime metallib did not bind")
        let hardware = try HardwareDetector.detect()
        let capabilities = ProviderRuntimeCapabilityDetector.detectPrepared(
            hardware: hardware, boundMetallibHash: fixture.metallibSHA256)
        let harness = try ReleaseCoResidencyHarness(fixture: fixture, fixtureSHA256: digest,
            hardware: hardware, runtimeCapabilities: capabilities)
        var failure: (any Error)?
        do { try await harness.run() } catch { failure = error }
        let clean = await harness.cleanup()
        do { try fixture.verifyModels() } catch { if failure == nil { failure = error } }
        try await harness.report(failure: failure.map { String(describing: $0) },
                                 complete: failure == nil && clean, cleanupComplete: clean)
        if let failure { throw failure }
        try #require(clean, "all native/load/SSD ledger owners must retire before the test returns")
    }
}
