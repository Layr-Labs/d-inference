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
    if name == "cooling" { return await cooling() }
    let paths = [
      "cloud": "/v1/provider/desktop", "network": "/v1/stats", "leaderboard": "/v1/leaderboard",
      "release": "/v1/releases/latest",
    ]
    guard let path = paths[name] else { throw HTTPError(.notFound, message: "Unknown resource") }
    let config = try configuration().config
    if name == "cloud", AuthTokenStore.load() == nil {
      return .dict([
        "linked": .bool(false), "observed_at": .number(Date().timeIntervalSince1970),
        "machines": .array([]),
      ])
    }
    let base = config.coordinator.url.replacingOccurrences(of: "wss://", with: "https://")
      .replacingOccurrences(of: "ws://", with: "http://")
    guard var components = URLComponents(string: base) else { throw URLError(.badURL) }
    components.path = path
    components.query = nil
    components.fragment = nil
    if name == "leaderboard" {
      components.queryItems = [URLQueryItem(name: "metric", value: "tokens")]
    }
    guard let url = components.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    if name == "cloud", let token = AuthTokenStore.load() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if name == "cloud", let identity = DaemonStateFile.read()?.attestationPublicKey {
      request.setValue(identity, forHTTPHeaderField: "X-Darkbloom-Device-Identity")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 4_000_000
    else {
      throw URLError(.badServerResponse)
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw URLError(.cannotParseResponse)
    }
    if name == "network" {
      return .dict([
        "total_tokens": Self.integerText(value.field("total_tokens")),
        "total_requests": Self.integerText(value.field("total_requests")),
        "total_macs": value.field("active_providers"),
      ])
    }
    if name == "leaderboard" {
      return .array(
        value.field("entries").values.map { entry in
          .dict([
            "rank": entry.field("rank"), "name": entry.field("pseudonym"),
            "tokens": Self.integerText(entry.field("tokens")),
            "earnings_micro_usd": Self.integerText(entry.field("earnings_micro_usd")),
          ])
        })
    }
    if name == "release" {
      return .dict([
        "version": value.field("version"), "published_at": value.field("created_at"),
        "notes": value.field("changelog"),
      ])
    }
    if name == "cloud", case .object(let pairs) = value {
      let machines = value.field("machines").values
      var fields = Dictionary(uniqueKeysWithValues: pairs)
      fields["machines"] = .array(machines.filter { $0.field("is_this_mac").flag != true })
      fields["local_earnings_micro_usd"] =
        machines.first { $0.field("is_this_mac").flag == true }?.field("earnings_micro_usd")
        ?? .null
      return .dict(fields)
    }
    return value
  }
}
