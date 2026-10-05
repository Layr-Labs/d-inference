import Foundation
import Testing
@testable import ProviderCore

private struct CoverageFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let calibrationSampleCount: Int
        let validationSampleCount: Int
        let validationCoveredCount: Int
        let tailCoverage: Double
        let valid: Bool
    }
    let cases: [Case]
}

@Test func deadlineCoverageMatchesPythonConfidenceBoundAndCatalogValidation() throws {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("coordinator/protocol").path) {
        let parent = root.deletingLastPathComponent()
        guard parent != root else { throw CocoaError(.fileNoSuchFile) }
        root = parent
    }
    let data = try Data(contentsOf: root.appendingPathComponent("coordinator/tests/protocol/testdata/deadline_coverage_confidence.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let shared = try decoder.decode(CoverageFixture.self, from: data)
    #expect(shared.cases.count == 16)
    for row in shared.cases {
        var profile = deadlineCalibrationProfileFixture()
        profile.deadlineCalibration.cells[0].calibrationSampleCount = row.calibrationSampleCount
        profile.deadlineCalibration.cells[0].validationSampleCount = row.validationSampleCount
        profile.deadlineCalibration.cells[0].validationCoveredCount = row.validationCoveredCount
        profile.deadlineCalibration.cells[0].tailCoverage = row.tailCoverage
        #expect(profile.isValid == row.valid, "\(row.name)")
        let json = try #require(String(data: JSONEncoder().encode([profile]), encoding: .utf8))
        #expect(DeadlineProfileCatalog.decode(json).isEmpty != row.valid, "\(row.name)")
    }
}

@Test func deadlineCoverageRefusesUnboundedOrNonfiniteEditedCounts() {
    for mutate: (inout DeadlineCalibrationCell) -> Void in [
        { $0.calibrationSampleCount = .max },
        { $0.validationSampleCount = .max; $0.validationCoveredCount = .max },
        { $0.validationCoveredCount = -1 }, { $0.validationCoveredCount = 101 },
        { $0.tailCoverage = .nan }, { $0.tailCoverage = .infinity },
    ] {
        var profile = deadlineCalibrationProfileFixture()
        mutate(&profile.deadlineCalibration.cells[0])
        #expect(!profile.isValid)
    }
}
