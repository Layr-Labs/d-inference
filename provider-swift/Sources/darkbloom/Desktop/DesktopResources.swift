import Foundation
import Hummingbird
import ProviderCore

extension DesktopBackend {
  static func integerText(_ value: JSONValue) -> JSONValue {
    switch value {
    case .int(let number): return .string(String(number))
    case .string: return value
    default: return .null
    }
  }

  func resource(_ name: String) async throws -> JSONValue {
    if name == "state" { return try await state() }
    if name == "endpoint-key" {
      guard let endpoint = LocalEndpoint.readLiveInfo() else { return .null }
      return .dict(["key": .string(endpoint.apiKey)])
    }
    if name == "request-history" { return try await requestHistory() }
    if name == "cooling" { return await cooling() }
    let base = coordinatorHTTPBase(try configuration().config.coordinator.url)
    let token = (name == "cloud" || name.hasPrefix("insights-")) ? accountReadToken() : nil
    if name == "cloud", token == nil {
      return .dict(["linked": .bool(false), "observed_at": .number(Date().timeIntervalSince1970), "machines": .array([])])
    }
    if name.hasPrefix("insights-"), token == nil {
      throw HTTPError(.unauthorized, message: "Sign in to view account earnings")
    }
    return try await cachedResource(name, base: base, token: token, ttl: name.hasPrefix("release") ? 3600 : 30)
  }

  func readRemoteResource(_ name: String, base: String, token: String?) async throws -> JSONValue {
    if name == "cloud", let token {
      if token.hasPrefix("darkbloom-at-") { return try await accountCloud(base: base, token: token) }
      return try DesktopAccountEarnings(try await accountEarnings(base: base, token: token), localKeys: Set(usageArchive.providerKeys.keys)).cloud()
    }
    if name.hasPrefix("insights-"), let token {
      let window = name == "insights-week" ? "7d" : "30d"
      if !token.hasPrefix("darkbloom-at-") {
        return try DesktopAccountEarnings(try await accountEarnings(base: base, token: token), localKeys: Set(usageArchive.providerKeys.keys)).insights(window)
      }
      let value = try await Self.readUsageJSON(base: base, path: "/v1/provider/account-earnings", token: token, query: [URLQueryItem(name: "window", value: window)])
      if value.field("window").text == window { return Self.localizeInsights(value, providerID: usageArchive.localProviderID) }
      // Older coordinators ignore window: preserve truthful partial-history coverage.
      return try DesktopAccountEarnings(try await accountEarnings(base: base, token: token), localKeys: Set(usageArchive.providerKeys.keys)).insights(window)
    }
    let paths = ["network": "/v1/stats", "leaderboard": "/v1/leaderboard", "release": "/v1/releases/latest", "release-history": "/v1/releases/latest", "owned-providers": "/v1/me/providers", "summary": "/v1/me/summary", "legacy-roster": "/v1/providers/attestation"]
    guard let path = paths[name] else { throw HTTPError(.notFound, message: "Unknown resource") }
    if name == "release-history" {
      let latest = try await cachedResource("release", base: base, token: nil, ttl: 3600)
      return .dict(["history": .array([.dict(["version": latest.field("version"), "published_at": latest.field("published_at"), "notes": latest.field("notes"), "active": .bool(true)])])])
    }
    let query = name == "leaderboard" ? [URLQueryItem(name: "metric", value: "earnings"), URLQueryItem(name: "window", value: "24h")] : []
    let value = try await Self.readUsageJSON(base: base, path: path, token: token, query: query)
    if name == "network" {
      return .dict([
        "total_tokens": Self.integerText(value.field("total_tokens")),
        "total_requests": Self.integerText(value.field("total_requests")),
        "total_macs": value.field("active_providers"),
        "provider_regions": value.field("provider_regions"),
      ])
    }
    if name == "leaderboard" {
      let entries: [JSONValue] = value.field("entries").values.map { entry in
        .dict([
          "rank": entry.field("rank"), "name": entry.field("pseudonym"),
          "tokens": Self.integerText(entry.field("tokens")),
          "earnings_micro_usd": Self.integerText(entry.field("earnings_micro_usd")),
        ])
      }
      return .dict([
        "metric": value.field("metric"), "window": value.field("window"),
        "entries": .array(entries),
      ])
    }
    if name == "release" {
      return .dict([
        "version": value.field("version"), "published_at": value.field("created_at"),
        "notes": value.field("changelog"),
      ])
    }
    return value
  }
}
