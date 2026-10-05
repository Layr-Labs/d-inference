import Crypto
import Foundation
import ProviderCore

struct DesktopResourceCache: Sendable {
  let value: JSONValue
  let at: Date
}

extension DesktopBackend {
  /// One native cache/in-flight request per coordinator, credential and resource.
  func cachedResource(_ name: String, base: String, token: String?, ttl: Double = 30) async throws -> JSONValue {
    let hash = SHA256.hash(data: Data("\(base)\n\(token ?? "")\n\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
    if let cached = resourceCache[hash], Date().timeIntervalSince(cached.at) < ttl { return cached.value }
    let generation = resourceGeneration
    if let failure = resourceFailures[hash], failure.retryAt > Date() { throw URLError(.cannotConnectToHost) }
    if let task = resourceTasks[hash] {
      let value = try await task.value
      guard generation == resourceGeneration else { throw URLError(.cancelled) }
      if let token, accountReadToken() != token { throw URLError(.userAuthenticationRequired) }
      return value
    }
    let task = Task { try await self.readRemoteResource(name, base: base, token: token) }
    resourceTasks[hash] = task
    defer { if generation == resourceGeneration { resourceTasks[hash] = nil } }
    let value: JSONValue
    do { value = try await task.value } catch {
      if (error as? URLError)?.code == .userAuthenticationRequired, let token,
        token.hasPrefix("darkbloom-at-"), accountCredentialToken() == token {
        try? DesktopAccountCredential.remove(base: base)
        clearAccountResources()
      }
      if error is URLError, generation == resourceGeneration {
        let attempts = min((resourceFailures[hash]?.attempts ?? 0) + 1, 4)
        resourceFailures[hash] = (attempts, Date().addingTimeInterval(min(300, 30 * pow(2, Double(attempts - 1)))))
      }
      throw error
    }
    if let token, accountReadToken() != token { throw URLError(.userAuthenticationRequired) }
    guard generation == resourceGeneration else { throw URLError(.cancelled) }
    // Bound retained caches even if accounts or coordinator URLs change repeatedly.
    if resourceCache.count > 32 { resourceCache = [:] }
    resourceFailures[hash] = nil
    resourceCache[hash] = DesktopResourceCache(value: value, at: Date())
    return value
  }

  func refreshCatalogIfNeeded(coordinator: String, now: Date) {
    guard catalogTask == nil, now.timeIntervalSince(catalogAt) > 120 else { return }
    catalogAt = now
    let generation = resourceGeneration
    catalogTask = Task {
      defer { if generation == resourceGeneration { catalogTask = nil } }
      do {
        let models = try await ModelCatalogClient(coordinatorURL: coordinator).fetchCatalog(typeFilter: nil)
        guard generation == resourceGeneration, (try? configuration().config.coordinator.url) == coordinator else { return }
        catalog = models; catalogError = nil
      } catch { if generation == resourceGeneration { catalogError = "Model catalog unavailable. Downloaded models remain available." } }
    }
  }
}
