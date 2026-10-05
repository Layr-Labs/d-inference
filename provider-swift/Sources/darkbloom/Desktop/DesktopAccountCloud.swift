import Foundation
import ProviderCore

extension DesktopBackend {
  static func usageDate(_ value: String) -> Date? {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  func accountCloud(base: String, token: String) async throws -> JSONValue {
    async let fleetRead = cachedResource("owned-providers", base: base, token: token)
    async let summaryRead = cachedResource("summary", base: base, token: token)
    async let insightsRead = cachedResource("insights-week", base: base, token: token)
    let (fleet, summary) = try await (fleetRead, summaryRead)
    let insights = try? await insightsRead
    guard accountCredentialToken() == token else { throw URLError(.userAuthenticationRequired) }
    return Self.projectAccountCloud(fleet: fleet, summary: summary, identity: DaemonStateFile.read()?.attestationPublicKey, insights: insights)
  }

  static func projectAccountCloud(fleet: JSONValue, summary: JSONValue, identity: String?, insights: JSONValue? = nil) -> JSONValue {
    let providers = fleet.field("providers").values
    let local = identity.flatMap { key in providers.first { $0.field("se_public_key").text == key } }
    func money(_ id: String?) -> JSONValue {
      guard let id, let slice = insights?.field("machines").values.first(where: { $0.field("id").text == id }),
        let work = usageInteger(slice.field("work_micro_usd")), let reward = usageInteger(slice.field("base_reward_micro_usd")) else { return .null }
      return .string(String(work + reward))
    }
    let machines = providers.filter { provider in
      guard let identity, !identity.isEmpty else { return true }
      return provider.field("se_public_key").text != identity
    }.map { provider -> JSONValue in
      let hardware = provider.field("hardware")
      let slots = provider.field("backend_capacity").field("slots").values
      let loaded = slots.filter { ["running", "idle"].contains($0.field("state").text ?? "") }.compactMap { $0.field("model").text }
      let models = slots.isEmpty ? provider.field("warm_models").values : loaded.map(DV.string)
      let timestamp = provider.field("last_heartbeat").text ?? provider.field("last_seen").text
      return .dict([
        "id": provider.field("id"), "name": hardware.field("machine_model").text.map(DV.string) ?? .string("Mac"),
        "chip": hardware.field("chip_name"), "memory_gb": hardware.field("memory_gb"),
        "status": provider.field("status"), "version": provider.field("version"),
        "earnings_micro_usd": money(provider.field("id").text),
        "observed_at": .number(timestamp.flatMap(Self.usageDate)?.timeIntervalSince1970), "models": .array(models),
      ])
    }
    return .dict([
      "linked": .bool(true), "account_id": summary.field("account_id"),
      "observed_at": .number(Date().timeIntervalSince1970), "machines": .array(machines),
      "lifetime_micro_usd": integerText(summary.field("lifetime_micro_usd")),
      "week_micro_usd": integerText(summary.field("last_7d_micro_usd")),
      "balance_micro_usd": integerText(summary.field("withdrawable_balance_micro_usd")),
      "earnings_complete": .bool(true), "local_provider_id": local?.field("id") ?? .null,
      "minimum_provider_version": fleet.field("min_provider_version"),
      "local_earnings_micro_usd": money(insights?.field("machines").values.contains(where: { $0.field("id").text == "this-mac" }) == true ? "this-mac" : local?.field("id").text),
    ])
  }

  static func localizeInsights(_ value: JSONValue, providerID: String?) -> JSONValue {
    guard let providerID, case .object(let pairs) = value else { return value }
    var fields = Dictionary(uniqueKeysWithValues: pairs)
    fields["machines"] = .array(value.field("machines").values.map { machine in
      guard machine.field("id").text == providerID, case .object(let pairs) = machine else { return machine }
      var fields = Dictionary(uniqueKeysWithValues: pairs); fields["id"] = .string("this-mac")
      return .dict(fields)
    })
    return .dict(fields)
  }
}
