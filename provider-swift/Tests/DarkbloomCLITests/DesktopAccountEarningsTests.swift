import Foundation
import ProviderCore
import Testing
@testable import darkbloom

struct DesktopAccountEarningsTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-04T18:00:00Z")!
  func row(_ id: Int64, key: String, model: String = "test", amount: Int64, at: String, input: Int64 = 120, output: Int64 = 30) -> JSONValue {
    .dict(["id": .int(id), "provider_key": .string(key), "model": .string(model),
      "amount_micro_usd": .int(amount), "prompt_tokens": .int(input), "completion_tokens": .int(output), "created_at": .string(at)])
  }
  func ledger(_ rows: [JSONValue], lifetime: Int64, count: Int64) -> JSONValue {
    .dict(["account_id": .string("test-account"), "total_micro_usd": .int(lifetime), "count": .int(count),
      "available_balance_micro_usd": .int(7000), "earnings": .array(rows)])
  }
  @Test func combinesMacsOnceAndSeparatesRewardsWithoutChangingLifetimeSummary() throws {
    let own = row(1, key: "own", amount: 1000, at: "2026-10-04T10:00:00Z")
    let other = row(2, key: "other", amount: 2000, at: "2026-10-03T10:00:00Z")
    let reward = row(3, key: "own", model: "base_reward", amount: 5000, at: "2026-10-04T12:00:00Z", input: 0, output: 0)
    let earnings = try DesktopAccountEarnings(ledger([own, other, reward, own], lifetime: 8000, count: 2), localKeys: ["own"], now: now)
    let cloud = earnings.cloud(), insights = earnings.insights("7d")
    #expect(cloud.field("lifetime_micro_usd").text == "8000")
    #expect(cloud.field("week_micro_usd").text == "8000")
    #expect(cloud.field("local_earnings_micro_usd").text == "6000")
    #expect(cloud.field("earnings_complete").flag == true)
    #expect(insights.field("totals").field("work_micro_usd").text == "3000")
    #expect(insights.field("totals").field("base_reward_micro_usd").text == "5000")
    #expect(insights.field("totals").field("jobs").text == "2")
    #expect(insights.field("totals").field("prompt_tokens").text == "240")
    #expect(insights.field("days").values.count == 7)
  }
  @Test func truncatedRecentRecordsDoNotPretendToCoverSevenDaysOrLifetimeTokens() throws {
    let earnings = try DesktopAccountEarnings(ledger([row(1, key: "own", amount: 1000, at: "2026-10-04T10:00:00Z")], lifetime: 900000, count: 5000), localKeys: [], now: now)
    let cloud = earnings.cloud(), insights = earnings.insights("7d")
    #expect(cloud.field("lifetime_micro_usd").text == "900000")
    #expect(cloud.field("week_micro_usd").text == "1000")
    #expect(cloud.field("earnings_complete").flag == false)
    #expect(cloud.field("local_earnings_micro_usd") == .null)
    #expect(cloud.field("local_day_micro_usd") == .null)
    #expect(insights.field("history_complete").flag == false)
    #expect(insights.field("lifetime").field("completion_tokens") == .null)
    #expect(insights.field("days").values.count == 7)
    #expect(insights.field("days").values.filter { $0.field("available").flag == false }.count == 6)
    #expect(insights.field("days").values.last?.field("complete").flag == false)
  }
  @Test func olderPageBoundaryProvesWeekCoverageButNotMonthCoverage() throws {
    let earnings = try DesktopAccountEarnings(ledger([
      row(1, key: "own", amount: 9999, at: "2026-09-27T10:00:00Z"),
      row(2, key: "own", amount: 1000, at: "2026-10-04T10:00:00Z")], lifetime: 900000, count: 5000), localKeys: ["own"], now: now)
    #expect(earnings.cloud().field("earnings_complete").flag == true)
    #expect(earnings.cloud().field("week_micro_usd").text == "1000")
    #expect(earnings.insights("30d").field("history_complete").flag == false)
  }
  @Test func rejectsMalformedRowsInsteadOfInventingZeroEarnings() throws {
    #expect(throws: (any Error).self) {
      try DesktopAccountEarnings(ledger([.dict(["id": .int(1)])], lifetime: 1000, count: 1), localKeys: [], now: now)
    }
  }
}
