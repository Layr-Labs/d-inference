import Crypto
import Foundation
import ProviderCore

/// Native-only account credential, separate from AuthTokenStore and scoped to its coordinator.
struct DesktopAccountCredential: Codable, Sendable {
  let token: String
  let base: String
  let expiresAt: Date
  var email: String? = nil

  static func supports(token: String) -> Bool {
    token.hasPrefix("darkbloom-at-") || token.hasPrefix("eigeninference-pt-")
  }
  static func filename(base: String) -> String {
    let hash = SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    return "account-\(hash).json"
  }
  static func legacyAllowed(base: String) -> Bool {
    !(DesktopStorage.read(Bool.self, name: "disabled-" + filename(base: base)) ?? false)
  }
  static func load(base: String) -> Self? {
    guard let value = DesktopStorage.read(Self.self, name: filename(base: base)),
      value.base == base, Self.supports(token: value.token), value.expiresAt > Date()
    else { return nil }
    return value
  }
  static func save(token: String, base: String) throws {
    guard supports(token: token) else { throw URLError(.userAuthenticationRequired) }
    try DesktopStorage.write(true, name: "disabled-" + filename(base: base))
    // Cap local dashboard use at 30 days. Scoped sessions also expire on the server;
    // older coordinator provider grants have no server-side account-session expiry.
    try DesktopStorage.write(Self(token: token, base: base, expiresAt: Date().addingTimeInterval(30 * 86400 - 60)), name: filename(base: base))
  }
  static func remove(base: String) throws {
    try DesktopStorage.write(true, name: "disabled-" + filename(base: base))
    let url = DesktopStorage.directory.appendingPathComponent(filename(base: base))
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
}

extension DesktopBackend {
  func accountCredentialToken() -> String? {
    guard let config = try? configuration().config else { return nil }
    return DesktopAccountCredential.load(base: coordinatorHTTPBase(config.coordinator.url))?.token
  }
  func accountReadToken() -> String? {
    if let token = accountCredentialToken() { return token }
    guard let config = try? configuration().config,
      DesktopAccountCredential.legacyAllowed(base: coordinatorHTTPBase(config.coordinator.url)) else { return nil }
    return AuthTokenStore.load()
  }
  func usageCredentialToken() -> String? { accountCredentialToken() ?? AuthTokenStore.load() }
  func accountStatus() -> JSONValue {
    guard let config = try? configuration().config,
      let credential = DesktopAccountCredential.load(base: coordinatorHTTPBase(config.coordinator.url))
    else { return .dict(["signed_in": .bool(false), "legacy_data": .bool(accountReadToken() != nil)]) }
    return .dict(["signed_in": .bool(true), "email": credential.email.map(JSONValue.string) ?? .null,
      "expires_at": .number(credential.expiresAt.timeIntervalSince1970)])
  }
  func clearAccountResources() {
    resourceGeneration += 1
    accountIdentityRead?.cancel(); accountIdentityRead = nil; accountIdentityReadAt = .distantPast
    catalogTask?.cancel(); catalogTask = nil; catalogAt = .distantPast
    accountEarningsTask?.task.cancel(); accountEarningsTask = nil; accountEarningsCache = nil
    for task in resourceTasks.values { task.cancel() }; resourceTasks = [:]; resourceCache = [:]; resourceFailures = [:]
    usageRead?.cancel(); usageRead = nil; usageReadAt = .distantPast; usageArchive = DesktopUsageArchive()
  }
  static func revokeAccount(base: String, token: String) async throws {
    guard token.hasPrefix("darkbloom-at-") else { return }
    guard let url = URL(string: "\(base)/v1/device/token") else { throw URLError(.badURL) }
    var request = URLRequest(url: url); request.httpMethod = "DELETE"; request.timeoutInterval = 5
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    _ = try await URLSession.shared.data(for: request)
  }
}
