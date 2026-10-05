import Foundation
import ProviderCore

/// Persisted settlement metadata is scoped to the exact Mac, coordinator and account.
struct DesktopUsageArchive: Codable, Sendable {
  struct Settlement: Codable, Sendable, Equatable {
    let id: String
    var jobID: String? = nil
    let providerKey: String
    let completedAt: Double
    let input: UInt64
    let output: UInt64
    let earnings: UInt64
  }
  struct Totals: Codable, Sendable {
    var input: UInt64 = 0
    var output: UInt64 = 0
    var earnings: UInt64 = 0
    var requests: UInt64 = 0
  }
  var totalsByKey: [String: Totals] = [:]
  var scope = ""
  var localProviderID: String?
  var providerKeys: [String: Double] = [:]
  var settlements: [Settlement] = []
  var observedAt: Double?

  mutating func merge(_ records: [Settlement], providerID: String, identities: [String: String], sessionStartedAt: Double) {
    localProviderID = providerID
    for record in records where identities[record.id] == providerID {
      providerKeys[record.providerKey] = sessionStartedAt
    }
    var known = Dictionary(settlements.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    for record in records where providerKeys[record.providerKey] != nil {
      let previous = known[record.id]
      var totals = totalsByKey[record.providerKey] ?? Totals()
      totals.input = totals.input - (previous?.input ?? 0) + record.input
      totals.output = totals.output - (previous?.output ?? 0) + record.output
      totals.earnings = totals.earnings - (previous?.earnings ?? 0) + record.earnings
      if previous == nil { totals.requests += 1 }
      totalsByKey[record.providerKey] = totals
      known[record.id] = record
    }
    settlements = Array(known.values.sorted { $0.completedAt > $1.completedAt }.prefix(4096))
  }

  func totals(since: Double, requests: UInt64) -> JSONValue {
    guard observedAt != nil else { return .null }
    let rows = totalsByKey.filter { providerKeys[$0.key] == since }.map(\.value)
    let input = rows.reduce(UInt64(0)) { $0 + $1.input }
    let output = rows.reduce(UInt64(0)) { $0 + $1.output }
    let earned = rows.reduce(UInt64(0)) { $0 + $1.earnings }
    let counted = rows.reduce(UInt64(0)) { $0 + $1.requests }
    guard counted > 0 || requests == 0 else { return .null }
    return .dict([
      "processed_tokens": .string(String(input + output)),
      "processed_input_tokens": .string(String(input)),
      "processed_output_tokens": .string(String(output)),
      "counted_requests": .string(String(counted)),
      "pending_usage_requests": .string(String(requests > counted ? requests - counted : 0)),
      "earnings_micro_usd": .string(String(earned)),
      "usage_source": .string("settled-history"),
      "usage_observed_at": .number(observedAt),
    ])
  }
}
