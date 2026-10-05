import Foundation
import ProviderCore
import Testing
@testable import darkbloom

struct DesktopAccountCloudTests {
  @Test func identifiesThisMacByIdentityAndUsesAuthoritativeLoadedSlots() throws {
    let fleet = try JSONDecoder().decode(JSONValue.self, from: Data("""
      {"providers":[
        {"id":"local-id","se_public_key":"local-se"},
        {"id":"remote-id","se_public_key":"other-se","hardware":{"machine_model":"Mac Studio","chip_name":"Apple M3 Ultra","memory_gb":192},"status":"online","warm_models":["stale-model"],"backend_capacity":{"slots":[{"model":"idle-model","state":"idle"},{"model":"running-model","state":"running"},{"model":"crashed-model","state":"crashed"}]},"last_heartbeat":"2026-10-05T14:00:00.123Z"}
      ]}
      """.utf8))
    let summary: JSONValue = .dict(["account_id": .string("owner"), "lifetime_micro_usd": .int(9007199254740993), "last_7d_micro_usd": .int(100), "withdrawable_balance_micro_usd": .int(200)])
    let projected = DesktopBackend.projectAccountCloud(fleet: fleet, summary: summary, identity: "local-se")
    #expect(projected.field("lifetime_micro_usd").text == "9007199254740993")
    #expect(projected.field("local_provider_id").text == "local-id")
    let machines = projected.field("machines").values
    #expect(machines.count == 1)
    #expect(machines.first?.field("models").values.compactMap(\.text) == ["idle-model", "running-model"])
    #expect(machines.first?.field("se_public_key") == .null)
    #expect(machines.first?.field("observed_at").number != nil)
    #expect(machines.first?.field("earnings_micro_usd") == .null)
  }

  @Test func unknownLocalIdentityDoesNotHideAnOwnedMacOrInventZeroMoney() {
    let fleet: JSONValue = .dict(["providers": .array([.dict(["id": .string("remote"), "hardware": .dict([:]), "status": .string("offline")])])])
    let result = DesktopBackend.projectAccountCloud(fleet: fleet, summary: .dict([:]), identity: nil)
    #expect(result.field("machines").values.count == 1)
    #expect(result.field("lifetime_micro_usd") == .null)
    #expect(result.field("local_provider_id") == .null)
  }

  @Test func localizesOnlyTheVerifiedMachineInInsights() {
    let source: JSONValue = .dict(["machines": .array([.dict(["id": .string("local"), "jobs": .string("2")]), .dict(["id": .string("other"), "jobs": .string("5")])])])
    let result = DesktopBackend.localizeInsights(source, providerID: "local")
    #expect(result.field("machines").values.map { $0.field("id").text } == ["this-mac", "other"])
    #expect(DesktopBackend.localizeInsights(source, providerID: nil) == source)
  }
  @Test func localHistoryJoinsSettledMoneyByJobIDOnly() throws {
    let local = ProviderUsageRecord(id: "request", sessionStartedAt: 10, completedAt: 20, model: "model", inputTokens: 100, outputTokens: 20, cachedInputTokens: nil, reasoningTokens: nil, exact: true)
    var settlement = DesktopUsageArchive.Settlement(id: "ledger-row", providerKey: "key", completedAt: 30, input: 100, output: 20, earnings: 40)
    settlement.jobID = "request"
    let joined = try DesktopBackend.localRequestHistory([local], settlements: [settlement]).field("records").values[0]
    #expect(joined.field("earnings_micro_usd").text == "40")
    #expect(joined.field("completed_at").number == 20)
    #expect(joined.field("input_tokens").number == 100)
    settlement.jobID = "another-request"
    let pending = try DesktopBackend.localRequestHistory([local], settlements: [settlement]).field("records").values[0]
    #expect(pending.field("earnings_micro_usd") == .null)
  }

}
