import Foundation
import Hummingbird
import ProviderCore

extension DesktopBackend {
  static func localRequestHistory(_ records: [ProviderUsageRecord], settlements: [DesktopUsageArchive.Settlement]) throws -> JSONValue {
    guard records.allSatisfy({ $0.inputTokens <= 9_007_199_254_740_991 && $0.outputTokens <= 9_007_199_254_740_991 }) else { throw URLError(.cannotParseResponse) }
    let money = Dictionary(settlements.compactMap { row in row.jobID.map { ($0, row) } }, uniquingKeysWith: { _, last in last })
    let sorted = records.sorted { $0.completedAt > $1.completedAt }
    return .dict([
      "observed_at": .number(Date().timeIntervalSince1970), "since": .number(sorted.last?.completedAt),
      "records": .array(sorted.map { record in .dict([
        "id": .string(record.id), "completed_at": .number(record.completedAt),
        "model": .string(record.model), "input_tokens": .int(Int64(clamping: record.inputTokens)),
        "output_tokens": .int(Int64(clamping: record.outputTokens)), "outcome": .string("completed"),
        "earnings_micro_usd": money[record.id].map { .string(String($0.earnings)) } ?? .null,
      ]) })
    ])
  }
  func requestHistory() async throws -> JSONValue {
    if let daemon = DaemonStateFile.read(), daemon.processIdentity?.isCurrent() == true {
      let local = ProviderUsageHistory.read().filter { $0.sessionStartedAt == daemon.startedAt && $0.exact }
      if !local.isEmpty {
        refreshUsageHistoryIfNeeded(daemon: daemon, now: Date())
        return try Self.localRequestHistory(local, settlements: usageArchive.settlements)
      }
    }
    guard let token = usageCredentialToken() else { throw HTTPError(.unauthorized, message: "Link your account to view history") }
    if let daemon = DaemonStateFile.read() {
      refreshUsageHistoryIfNeeded(daemon: daemon, now: Date())
      if let usageRead { await usageRead.value }
    }
    let base = coordinatorHTTPBase(try configuration().config.coordinator.url)
    let scope = usageArchive.scope
    let ledger = try await accountEarnings(base: base, token: token)
    guard scope == usageArchive.scope else { throw HTTPError(.unauthorized, message: "Mac identity changed; refresh to continue") }
    return try DesktopAccountEarnings(ledger, localKeys: Set(usageArchive.providerKeys.keys)).requestHistory()
  }
}

extension DesktopAccountEarnings {
  func requestHistory() throws -> JSONValue {
    guard !localKeys.isEmpty else { throw HTTPError(.serviceUnavailable, message: "This Mac's identity is not verified yet") }
    let local = rows.filter { localKeys.contains($0.key) && $0.model != "base_reward" }
    guard local.allSatisfy({ $0.input <= 9_007_199_254_740_991 && $0.output <= 9_007_199_254_740_991 }) else { throw URLError(.cannotParseResponse) }
    return .dict([
      "observed_at": .number(now.timeIntervalSince1970),
      "since": local.first.map { .number($0.at.timeIntervalSince1970) } ?? .null,
      "records": .array(local.reversed().map { row in .dict([
        "id": .string(row.id), "settled_at": .number(row.at.timeIntervalSince1970),
        "model": .string(row.model), "input_tokens": .int(Int64(row.input)),
        "output_tokens": .int(Int64(row.output)), "outcome": .string("settled"),
        "earnings_micro_usd": .string(String(row.money)),
      ]) })
    ])
  }
}
