import Crypto
import Foundation
import ProviderCore

extension DesktopBackend {
  /// Called by state polling, with one network refresh shared across readers.
  func refreshUsageHistoryIfNeeded(daemon: DaemonState, now: Date) {
    guard let token = usageCredentialToken(), let identity = daemon.attestationPublicKey else {
      usageArchive = DesktopUsageArchive()
      return
    }
    let configuredBase = coordinatorHTTPBase((try? configuration().config.coordinator.url) ?? "")
    let base = coordinatorHTTPBase(daemon.coordinatorUrl ?? configuredBase)
    // A daemon from another coordinator must never receive this account session.
    guard base == configuredBase else { return }
    let scope = SHA256.hash(data: Data("\(base)\n\(identity)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    if usageArchive.scope != scope {
      let saved = DesktopStorage.read(DesktopUsageArchive.self, name: "usage-history.json")
      let legacyBase = daemon.coordinatorUrl ?? (try? configuration().config.coordinator.url) ?? ""
      let legacyScope = SHA256.hash(data: Data("\(legacyBase)\n\(identity)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
      if let saved, saved.scope == scope || saved.scope == legacyScope {
        usageArchive = saved
        usageArchive.scope = scope
      } else { usageArchive = DesktopUsageArchive(scope: scope) }
      usageReadAt = .distantPast
    }
    guard usageRead == nil, now.timeIntervalSince(usageReadAt) >= 30 else { return }
    usageReadAt = now
    let generation = resourceGeneration
    usageRead = Task {
      defer { if generation == resourceGeneration { usageRead = nil } }
      do {
        async let roster = cachedResource(token.hasPrefix("darkbloom-at-") ? "owned-providers" : "legacy-roster", base: base, token: token.hasPrefix("darkbloom-at-") ? token : nil, ttl: 300)
        async let ledger = accountEarnings(base: base, token: token)
        let (providers, history) = try await (roster, ledger)
        guard generation == resourceGeneration, usageCredentialToken() == token, usageArchive.scope == scope,
          DaemonStateFile.read()?.startedAt == daemon.startedAt,
          let provider = providers.field("providers").values.first(where: { $0.field("se_public_key").text == identity }),
          let providerID = provider.field("id").text ?? provider.field("provider_id").text else { return }
        let (records, identities) = Self.parseUsageSettlements(history)
        if !history.field("earnings").values.isEmpty && records.isEmpty { throw URLError(.cannotParseResponse) }
        usageArchive.merge(records, providerID: providerID, identities: identities, sessionStartedAt: daemon.startedAt)
        usageArchive.observedAt = Date().timeIntervalSince1970
        try DesktopStorage.write(usageArchive, name: "usage-history.json")
      } catch {
        // Keep the last verified records; absent usage never becomes zero.
      }
    }
  }

  static func usageInteger(_ value: JSONValue) -> UInt64? {
    switch value {
    case .int(let v): return v >= 0 ? UInt64(v) : nil
    case .string(let v): return UInt64(v)
    default: return nil
    }
  }

  static func readUsageJSON(base: String, path: String, token: String?, query: [URLQueryItem] = []) async throws -> JSONValue {
    guard var url = URLComponents(string: base.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://")) else { throw URLError(.badURL) }
    url.path = path; url.query = nil; url.fragment = nil
    url.queryItems = !query.isEmpty ? query : (path == "/v1/provider/account-earnings" ? [URLQueryItem(name: "limit", value: "1000")] : nil)
    guard let endpoint = url.url else { throw URLError(.badURL) }
    var request = URLRequest(url: endpoint); request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await URLSession.shared.data(for: request)
    if let status = (response as? HTTPURLResponse)?.statusCode, [401, 403].contains(status), token?.hasPrefix("darkbloom-at-") == true { throw URLError(.userAuthenticationRequired) }
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_000_000 else { throw URLError(.badServerResponse) }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  func sessionUsage(daemon: DaemonState?, fresh: Bool, now: Date) -> [String: JSONValue] {
    guard fresh, let daemon else { return [:] }
    refreshUsageHistoryIfNeeded(daemon: daemon, now: now)
    var fields: [String: JSONValue] = [:]
    if case .object(let pairs) = usageArchive.totals(since: daemon.startedAt, requests: daemon.stats.requestsServed) {
      fields = Dictionary(uniqueKeysWithValues: pairs)
    }
    if let input = daemon.stats.promptTokensProcessed, daemon.stats.usageGaps == 0 {
      let output = daemon.stats.tokensGenerated
      fields["processed_tokens"] = .string(String(input + output))
      fields["processed_input_tokens"] = .string(String(input))
      fields["processed_output_tokens"] = .string(String(output))
      fields["cached_input_tokens"] = daemon.stats.cachedInputTokens.map { .string(String($0)) } ?? .null
      fields["reasoning_tokens"] = daemon.stats.reasoningTokens.map { .string(String($0)) } ?? .null
      fields["usage_source"] = .string("local")
      fields["counted_requests"] = .string(String(daemon.stats.requestsServed))
      fields["pending_usage_requests"] = .string("0")
    } else if daemon.stats.promptTokensProcessed != nil {
      let records = ProviderUsageHistory.read().filter { $0.sessionStartedAt == daemon.startedAt && $0.exact }
      let input = records.reduce(UInt64(0)) { $0 + $1.inputTokens }
      let output = records.reduce(UInt64(0)) { $0 + $1.outputTokens }
      fields["processed_tokens"] = .string(String(input + output))
      fields["processed_input_tokens"] = .string(String(input))
      fields["processed_output_tokens"] = .string(String(output))
      fields["counted_requests"] = .string(String(records.count))
      fields["pending_usage_requests"] = .string(String(max(daemon.stats.requestsServed, UInt64(records.count)) - UInt64(records.count)))
      fields["usage_source"] = .string("local")
    } else if daemon.stats.requestsServed == 0 {
      fields["processed_tokens"] = .string("0")
      fields["processed_input_tokens"] = .string("0")
      fields["processed_output_tokens"] = .string("0")
      fields["counted_requests"] = .string("0")
      fields["pending_usage_requests"] = .string("0")
    }
    return fields
  }
}
