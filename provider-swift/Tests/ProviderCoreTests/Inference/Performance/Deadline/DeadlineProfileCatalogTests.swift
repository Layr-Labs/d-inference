import Foundation
import Testing
@testable import ProviderCore

@Test func deadlineProfileCatalogFailsClosedForMalformedInvalidAndDuplicateRecords() throws {
    let profile = deadlineCalibrationProfileFixture()
    let data = try JSONEncoder().encode(profile)
    let valid = try #require(String(data: data, encoding: .utf8))
    #expect(DeadlineProfileCatalog.decode("[\(valid)]") == [profile])
    var invalid = profile
    invalid.qualificationReportSha256 = "not-evidence"
    let bad = try #require(String(data: JSONEncoder().encode(invalid), encoding: .utf8))
    for json in ["{", "{}", "null", "[null]", "[\(valid),null]", "[\(valid),\(bad)]", "[\(valid),\(valid)]"] {
        #expect(DeadlineProfileCatalog.decode(json).isEmpty)
    }
}

@Test func compiledDeadlineCatalogContainsOnlyValidUniqueProfiles() throws {
    let decoded = try JSONDecoder().decode([DeadlinePerformanceProfile].self,
        from: Data(ReviewedDeadlineProfilesData.json.utf8))
    #expect(DeadlineProfileCatalog.decode(ReviewedDeadlineProfilesData.json) == decoded)
    #expect(DeadlinePerformanceProfiles.reviewed == decoded)
}
