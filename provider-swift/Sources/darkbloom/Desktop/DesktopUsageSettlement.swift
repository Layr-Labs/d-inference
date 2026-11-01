import Foundation
import ProviderCore

extension DesktopBackend {
  static func parseUsageSettlements(_ history: JSONValue) -> ([DesktopUsageArchive.Settlement], [String: String]) {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var identities: [String: String] = [:]
    let records = history.field("earnings").values.compactMap { row -> DesktopUsageArchive.Settlement? in
      guard let id = Self.integerText(row.field("id")).text,
        let key = row.field("provider_key").text,
        let providerID = row.field("provider_id").text,
        let timestamp = row.field("created_at").text,
        let time = iso.date(from: timestamp) ?? plain.date(from: timestamp),
        let input = Self.usageInteger(row.field("prompt_tokens")),
        let output = Self.usageInteger(row.field("completion_tokens")),
        let earned = Self.usageInteger(row.field("amount_micro_usd")) else { return nil }
      identities[id] = providerID
      var record = DesktopUsageArchive.Settlement(id: id, providerKey: key, completedAt: time.timeIntervalSince1970,
                   input: input, output: output, earnings: earned)
      record.jobID = row.field("job_id").text
      return record
    }
    return (records, identities)
  }
}
