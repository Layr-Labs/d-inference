import Foundation
import ProviderCore
import Testing
@testable import darkbloom

struct DesktopMacStatsTests {
  @Test func settledHistoryOnlyContainsVerifiedMacAndDoesNotInventTiming() throws {
    let fixtures = DesktopAccountEarningsTests()
    let ledger = fixtures.ledger([
      fixtures.row(1, key: "mine", amount: 100, at: "2026-10-04T10:00:00Z"),
      fixtures.row(2, key: "another-mac", amount: 10000, at: "2026-10-04T11:00:00Z"),
      fixtures.row(3, key: "mine", model: "base_reward", amount: 500, at: "2026-10-04T12:00:00Z")
    ], lifetime: 10600, count: 2)
    let data = try DesktopAccountEarnings(ledger, localKeys: ["mine"], now: fixtures.now).requestHistory()
    let records = data.field("records").values
    #expect(records.count == 1)
    #expect(records.first?.field("id").text == "1")
    #expect(records.first?.field("outcome").text == "settled")
    #expect(records.first?.field("input_tokens") == .int(120))
    #expect(records.first?.field("earnings_micro_usd").text == "100")
    #expect(records.first?.field("started_at") == .null)
    #expect(records.first?.field("duration_ms") == .null)
    #expect(throws: (any Error).self) {
      try DesktopAccountEarnings(ledger, localKeys: [], now: fixtures.now).requestHistory()
    }
  }
  @Test func fanResolutionUsesOnlyVerifiedCandidatesAndHandlesRejectedSignature() throws {
    let preview = URL(fileURLWithPath: "/preview/unsigned"), installed = URL(fileURLWithPath: "/signed/Darkbloom.app/Contents/MacOS/darkbloom")
    var seen: [URL] = []
    let selected = try DesktopFanRuntime.select([preview, installed]) { candidate in
      seen.append(candidate)
      if candidate == preview { throw URLError(.noPermissionsToReadFile) }
      return candidate == installed
    }
    #expect(selected == installed)
    #expect(seen == [preview, installed])
    #expect(throws: (any Error).self) { try DesktopFanRuntime.select([preview, installed]) { _ in false } }
    #expect(try DesktopFanRuntime.select([installed, preview]) { $0 == installed } == installed)
  }
}
