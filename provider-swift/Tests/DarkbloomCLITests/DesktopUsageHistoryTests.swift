import Foundation
import ProviderCore
import Testing
@testable import darkbloom

struct DesktopUsageHistoryTests {
  @Test func historyDeduplicatesAndScopesBothMacAndSession() throws {
    var history = DesktopUsageArchive()
    let own = DesktopUsageArchive.Settlement(id: "one", providerKey: "own-key", completedAt: 120, input: 120, output: 30, earnings: 1000)
    let other = DesktopUsageArchive.Settlement(id: "other", providerKey: "other-key", completedAt: 120, input: 9000, output: 500, earnings: 5000)
    history.merge([own, other], providerID: "this-mac", identities: ["one": "this-mac", "other": "other-mac"], sessionStartedAt: 100)
    history.merge([own, other], providerID: "this-mac", identities: ["one": "this-mac", "other": "other-mac"], sessionStartedAt: 100)
    history.observedAt = 130
    let value = history.totals(since: 100, requests: 2)
    #expect(value.field("processed_tokens").text == "150")
    #expect(value.field("processed_input_tokens").text == "120")
    #expect(value.field("processed_output_tokens").text == "30")
    #expect(value.field("earnings_micro_usd").text == "1000")
    #expect(value.field("pending_usage_requests").text == "1")
    #expect(history.settlements.count == 1)
    #expect(history.totals(since: 200, requests: 0).field("processed_tokens").text == "0")
    let restored = try JSONDecoder().decode(DesktopUsageArchive.self, from: JSONEncoder().encode(history))
    #expect(restored.totals(since: 100, requests: 2) == value)
  }
  @Test func trimmingOldRowsPreservesAccumulatedSessionTotals() {
    var history = DesktopUsageArchive()
    let records = (0..<4200).map { index in
      DesktopUsageArchive.Settlement(id: String(index), providerKey: "own-key", completedAt: Double(index), input: 10, output: 5, earnings: 1)
    }
    history.merge(records, providerID: "this-mac", identities: Dictionary(uniqueKeysWithValues: records.map { ($0.id, "this-mac") }), sessionStartedAt: 100)
    history.observedAt = 5000
    history.merge(Array(records.suffix(1000)), providerID: "this-mac", identities: [:], sessionStartedAt: 100)
    #expect(history.settlements.count == 4096)
    #expect(history.totals(since: 100, requests: 4200).field("processed_tokens").text == "63000")
    #expect(history.totals(since: 100, requests: 4200).field("pending_usage_requests").text == "0")
  }
  @Test func aLaterSettlementOfThePreviousSessionStaysOutOfTheNewSession() {
    var history = DesktopUsageArchive()
    let old = DesktopUsageArchive.Settlement(id: "old", providerKey: "old-key", completedAt: 300, input: 120, output: 30, earnings: 1)
    let new = DesktopUsageArchive.Settlement(id: "new", providerKey: "new-key", completedAt: 250, input: 10, output: 5, earnings: 1)
    history.merge([old], providerID: "previous", identities: ["old": "previous"], sessionStartedAt: 100)
    history.merge([old, new], providerID: "current", identities: ["old": "previous", "new": "current"], sessionStartedAt: 200)
    history.observedAt = 400
    #expect(history.totals(since: 200, requests: 1).field("processed_tokens").text == "15")
  }
  @Test func settlementParserAcceptsTheProductionIntegerIDAndExactUsage() throws {
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"earnings":[{"id":221610837,"provider_id":"this-mac","provider_key":"key","prompt_tokens":120,"completion_tokens":30,"amount_micro_usd":1000,"created_at":"2026-10-04T17:20:00.367667Z"}]}"#.utf8))
    let (records, identities) = DesktopBackend.parseUsageSettlements(json)
    #expect(records.count == 1)
    #expect(records.first?.id == "221610837")
    #expect(records.first?.input == 120)
    #expect(records.first?.output == 30)
    #expect(identities["221610837"] == "this-mac")
  }
  @Test func absentHistoryIsUnknownAndIntegerUsageIsStrict() {
    #expect(DesktopUsageArchive().totals(since: 100, requests: 2) == .null)
    var observed = DesktopUsageArchive(); observed.observedAt = 130
    #expect(observed.totals(since: 100, requests: 2) == .null)
    #expect(DesktopBackend.usageInteger(.int(-1)) == nil)
    #expect(DesktopBackend.usageInteger(.double(1.5)) == nil)
    #expect(DesktopBackend.usageInteger(.string("9007199254740993")) == 9_007_199_254_740_993)
  }
}
