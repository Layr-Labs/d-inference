import Foundation
import Testing
@testable import DarkbloomApp

@Test("Contribution snapshots round-trip with integer money and privacy-safe fields")
@MainActor
func contributionSnapshotRoundTripIsExactAndPrivate() throws {
    let store = ContributionsStore(fixture: .active)
    let original = try #require(store.snapshot)
    let pulsePreview = try #require(store.pulsePreview)
    let encoder = JSONEncoder()
    let data = try encoder.encode(original)
    let decoded = try JSONDecoder().decode(ContributionsSnapshot.self, from: data)
    let json = String(decoding: data, as: UTF8.self)

    #expect(decoded == original)
    #expect(json.contains("\"availableBalance\":8750000"))
    #expect(!json.localizedCaseInsensitiveContains("prompt"))
    #expect(!json.localizedCaseInsensitiveContains("completion"))
    #expect(!json.localizedCaseInsensitiveContains("settlement"))
    #expect(!json.contains("earnedLast24Hours"))
    #expect(!json.contains("earnedLast7Days"))
    #expect(!json.contains("dailyPoints"))
    #expect(!json.contains("pulsePreview"))
    #expect(decoded.records.allSatisfy { !$0.providerKey.isEmpty })
    #expect(pulsePreview.points.count == 7)
    #expect(zip(pulsePreview.points, pulsePreview.points.dropFirst()).allSatisfy {
        $0.date < $1.date
    })
}

@Test("Malformed contribution snapshots fail decoding invariants")
@MainActor
func malformedContributionSnapshotsAreRejected() throws {
    let snapshot = try #require(ContributionsStore(fixture: .active).snapshot)
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["currentProviderKey"] = ""
    let malformed = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ContributionsSnapshot.self, from: malformed)
    }
}

@Test("Duplicate contribution IDs fail snapshot decoding")
@MainActor
func duplicateContributionIDsAreRejected() throws {
    let snapshot = try #require(ContributionsStore(fixture: .active).snapshot)
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var records = try #require(object["records"] as? [[String: Any]])
    records[1]["id"] = records[0]["id"]
    object["records"] = records
    let malformed = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ContributionsSnapshot.self, from: malformed)
    }
}

@Test("Contribution token totals saturate instead of wrapping")
func contributionTokenTotalsDoNotWrap() {
    let record = ContributionRecord(
        id: "overflow-check",
        timestamp: Date(timeIntervalSince1970: 1),
        providerKey: "stable-provider-key",
        providerID: "provider",
        providerName: "Provider",
        modelID: "model",
        modelName: "Model",
        inputTokens: .max,
        outputTokens: 1,
        amount: MicroUSD(1)
    )

    #expect(record.totalTokens == .max)
}
