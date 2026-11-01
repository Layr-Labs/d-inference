import Foundation
import ProviderCore

/// Read-only aggregation of the existing account earnings response.
/// Lifetime money comes from its summary; breakdowns only sum returned records.
struct DesktopAccountEarnings {
  struct Row {
    let id: String
    let at: Date
    let key: String
    let model: String
    let money: UInt64
    let input: UInt64
    let output: UInt64
  }
  struct Amounts {
    var work: UInt64 = 0, reward: UInt64 = 0, jobs: UInt64 = 0, input: UInt64 = 0, output: UInt64 = 0
    mutating func add(_ row: Row) {
      if row.model == "base_reward" { reward += row.money }
      else { work += row.money; jobs += 1; input += row.input; output += row.output }
    }
    var json: [String: JSONValue] {
      ["work_micro_usd": .string(String(work)), "base_reward_micro_usd": .string(String(reward)),
       "jobs": .string(String(jobs)), "prompt_tokens": .string(String(input)), "completion_tokens": .string(String(output))]
    }
  }
  let account: String
  let lifetime: UInt64
  let count: UInt64
  let balance: JSONValue
  let rows: [Row]
  let localKeys: Set<String>
  let now: Date

  init(_ value: JSONValue, localKeys: Set<String>, now: Date = Date()) throws {
    guard let account = value.field("account_id").text,
      let lifetime = DesktopBackend.usageInteger(value.field("total_micro_usd")),
      let count = DesktopBackend.usageInteger(value.field("count")) else { throw URLError(.cannotParseResponse) }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var unique: [String: Row] = [:]
    for item in value.field("earnings").values {
      guard let id = DesktopBackend.integerText(item.field("id")).text,
        let time = item.field("created_at").text, let at = iso.date(from: time) ?? plain.date(from: time),
        let key = item.field("provider_key").text, let model = item.field("model").text,
        let money = DesktopBackend.usageInteger(item.field("amount_micro_usd")),
        let input = DesktopBackend.usageInteger(item.field("prompt_tokens")),
        let output = DesktopBackend.usageInteger(item.field("completion_tokens")) else { throw URLError(.cannotParseResponse) }
      unique[id] = Row(id: id, at: at, key: key, model: model, money: money, input: input, output: output)
    }
    self.account = account; self.lifetime = lifetime; self.count = count
    self.balance = DesktopBackend.integerText(value.field("available_balance_micro_usd"))
    self.rows = unique.values.sorted { $0.at < $1.at }; self.localKeys = localKeys; self.now = now
  }

  var calendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
  }
  func start(_ window: String) -> Date {
    calendar.date(byAdding: .day, value: -(window == "30d" ? 29 : 6), to: calendar.startOfDay(for: now))!
  }
  var fullHistory: Bool {
    let totals = sum(rows)
    return totals.jobs == count && totals.work + totals.reward == lifetime
  }
  func complete(_ window: String) -> Bool {
    fullHistory || rows.first.map { $0.at <= start(window) } == true
  }
  func selected(_ window: String) -> [Row] { rows.filter { $0.at >= start(window) && $0.at <= now } }
  func sum(_ rows: [Row]) -> Amounts { rows.reduce(Amounts()) { totals, row in var totals = totals; totals.add(row); return totals } }

  func cloud() -> JSONValue {
    let recent = selected("7d")
    let local = recent.filter { localKeys.contains($0.key) }
    let localDay = local.filter { $0.at >= now.addingTimeInterval(-86400) }
    return .dict([
      "linked": .bool(true), "account_id": .string(account), "observed_at": .number(now.timeIntervalSince1970),
      "lifetime_micro_usd": .string(String(lifetime)), "week_micro_usd": .string(String(sum(recent).work + sum(recent).reward)),
      "balance_micro_usd": balance, "machines": .array([]),
      "local_earnings_micro_usd": localKeys.isEmpty ? .null : .string(String(sum(local).work + sum(local).reward)),
      "local_lifetime_micro_usd": .null,
      "local_day_micro_usd": !localKeys.isEmpty && (fullHistory || rows.first.map { $0.at <= now.addingTimeInterval(-86400) } == true)
        ? .string(String(sum(localDay).work + sum(localDay).reward)) : .null,
      "earnings_complete": .bool(complete("7d")),
      "earnings_since": .number((complete("7d") ? start("7d") : rows.first?.at ?? now).timeIntervalSince1970),
      "settled_records": .string(String(count)),
    ])
  }

  func insights(_ window: String) -> JSONValue {
    let selected = selected(window), totals = sum(selected), all = sum(rows)
    var days: [String: Amounts] = [:], models: [String: Amounts] = [:], machines: [String: Amounts] = [:]
    let iso = ISO8601DateFormatter()
    for row in selected {
      let day = String(iso.string(from: row.at).prefix(10))
      days[day, default: Amounts()].add(row)
      models[row.model, default: Amounts()].add(row)
      machines[localKeys.contains(row.key) ? "this-mac" : "", default: Amounts()].add(row)
    }
    let since = complete(window) ? start(window) : max(start(window), rows.first?.at ?? now)
    var date = start(window)
    while date <= now {
      days[String(iso.string(from: date).prefix(10)), default: Amounts()] = days[String(iso.string(from: date).prefix(10))] ?? Amounts()
      date = calendar.date(byAdding: .day, value: 1, to: date)!
    }
    func slices(_ values: [String: Amounts]) -> JSONValue {
      .array(values.keys.sorted().map { id in var fields = values[id]!.json; fields["id"] = .string(id); return .dict(fields) })
    }
    let daily = days.keys.sorted().map { id -> JSONValue in
      var fields = days[id]!.json
      fields["id"] = .string(id)
      let day = iso.date(from: "\(id)T00:00:00Z")!
      let covered = complete(window) || day >= calendar.startOfDay(for: since)
      fields["available"] = .bool(covered)
      fields["complete"] = .bool(covered && day >= since && day < calendar.startOfDay(for: now))
      return .dict(fields)
    }
    return .dict([
      "account_id": .string(account), "window": .string(window), "since": .string(iso.string(from: since)),
      "as_of": .string(iso.string(from: now)), "history_complete": .bool(complete(window)),
      "lifetime": .dict([
        "count": .string(String(count)), "total_micro_usd": .string(String(lifetime)),
        "prompt_tokens": fullHistory ? .string(String(all.input)) : .null,
        "completion_tokens": fullHistory ? .string(String(all.output)) : .null,
      ]),
      "totals": .dict(totals.json), "days": .array(daily), "models": slices(models), "machines": slices(machines),
    ])
  }
}
