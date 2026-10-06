import Foundation
import Testing
@testable import ProviderCore

@Test func deadlineCatalogRequiresExactCurrentPromoterContract() throws {
    let mutations: [(String, (inout DeadlinePerformanceProfile) -> Void)] = [
        ("parallel partial prefill", { $0.maxConcurrentPartialPrefills = 2 }),
        ("wide parallel partial prefill", { $0.maxConcurrentPartialPrefills = 16 }),
        ("unqualified mixed cap", { $0.mixedPrefillTokenCap = 64 }),
        ("zero cooldown", { $0.minimumWholeMacQuiescenceMs = 0 }),
        ("short cooldown", { $0.minimumWholeMacQuiescenceMs = 19_999 }),
        ("different cooldown", { $0.minimumWholeMacQuiescenceMs = 20_001 }),
        ("different stability", { $0.minimumNominalStabilityMs = 5_001 }),
        ("work beyond actual width", { $0.effectiveMaxConcurrency = 1
            $0.deadlineCalibration.cells[0].contention = "same_model"; $0.deadlineCalibration.cells[0].maxActiveRequests = 2 }),
        ("unrelated cell receipt", { $0.deadlineCalibration.cells[0].reportSha256 = String(repeating: "e", count: 64) }),
        ("prompt beyond cell context", { $0.deadlineCalibration.cells[0].contextTokensMax -= 1 }),
        ("too many cells", { $0.deadlineCalibration.cells = Array(repeating: $0.deadlineCalibration.cells[0], count: 129) }),
    ]
    for (name, mutate) in mutations {
        var profile = deadlineCalibrationProfileFixture()
        #expect(profile.isValid)
        mutate(&profile)
        #expect(!profile.isValid, "\(name)")
        let json = try #require(String(data: JSONEncoder().encode([profile]), encoding: .utf8))
        #expect(DeadlineProfileCatalog.decode(json).isEmpty, "\(name)")
    }
}

@Test func deadlineQualificationDoesNotRestrictOrdinarySchedulerConfiguration() {
    var profile = deadlineCalibrationProfileFixture()
    for cap in [128, 256, 512] {
        profile.mixedPrefillTokenCap = cap
        #expect(profile.isValid)
    }
    for partial in [2, 16] {
        var runtime = profile.runtimeConfiguration
        runtime.maxConcurrentPartialPrefills = partial
        #expect(runtime.isValid)
        #expect(!runtime.supportsQualifiedDeadline)
    }
    var runtime = profile.runtimeConfiguration
    runtime.mixedPrefillTokenCap = 64
    #expect(runtime.isValid)
    #expect(!runtime.supportsQualifiedDeadline)
}
