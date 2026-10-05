import Crypto
import Foundation
import ProviderCore

extension DesktopBackend {
  /// Session usage, fleet totals and charts share the same existing ledger read.
  func accountEarnings(base: String, token: String) async throws -> JSONValue {
    let key = SHA256.hash(data: Data("\(base)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    if let cached = accountEarningsCache, cached.key == key, Date().timeIntervalSince(cached.at) < 30 { return cached.value }
    let generation = resourceGeneration
    if let pending = accountEarningsTask, pending.key == key {
      let value = try await pending.task.value
      guard generation == resourceGeneration, usageCredentialToken() == token else { throw URLError(.userAuthenticationRequired) }
      return value
    }
    let task = Task { try await Self.readUsageJSON(base: base, path: "/v1/provider/account-earnings", token: token) }
    accountEarningsTask = (key, task)
    defer { if generation == resourceGeneration, accountEarningsTask?.key == key { accountEarningsTask = nil } }
    let value = try await task.value
    guard generation == resourceGeneration, usageCredentialToken() == token else { throw URLError(.userAuthenticationRequired) }
    accountEarningsCache = (key, Date(), value)
    return value
  }
}
