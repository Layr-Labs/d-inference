import ArgumentParser
import Foundation
import ProviderCore

typealias DV = JSONValue

extension JSONValue {
  static func dict(_ value: [String: JSONValue]) -> JSONValue {
    .object(value.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
  }
  static func number(_ value: Double?) -> JSONValue {
    value.map { $0.isFinite ? .double($0) : .null } ?? .null
  }
  func field(_ key: String) -> JSONValue {
    guard case .object(let pairs) = self else { return .null }
    return pairs.first { $0.0 == key }?.1 ?? .null
  }
  var text: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var number: Double? {
    switch self {
    case .int(let v): return Double(v)
    case .double(let v): return v
    default: return nil
    }
  }
  var flag: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  var values: [JSONValue] {
    if case .array(let values) = self { return values }
    return []
  }
  static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}

struct DesktopAction: Codable, Sendable, Equatable {
  let id: String
  let action: String
  var models: [String]?
  var pinned: [String]?
  var downloads: [String]?
  var model: String?
  var operation: String?
  var local: Bool?
  var endpoint: Bool?
  var revision: String?
  var name: String?
  var idle_minutes: UInt64?
  var auto_update: Bool?
  var schedule: ScheduleConfig?
  var startup_preload: Bool?
  var enabled: Bool?
  var speed: Int?
  var temperature: Int?
  // `start`: the Darkbloom network with no local API (`--network`); on a paired Mac, this Mac alone (`--solo`).
  var network: Bool?
  var solo: Bool?
  // `waitlist_join`.
  var feature: String?
  // `sandbox_setup`.
  var linux_slots: Int?
  var macos_slots: Int?
  var disks: [String]?
  var wait_ready: Bool?
  // `route`, `route_key` (the account API key: never kept, logged or passed as an argument), `local_settings`.
  var route: String?
  var key: String?
  var me_first: Bool?
  var me_first_idle_minutes: UInt64?
  // `tool_setup`.
  var tool: String?

  /// `startsThePair`: asked only for a `start` that names no models and doesn't serve this Mac alone, whether it starts
  /// this Mac's pair, which serves its own model (`DesktopBackend.startsThePair`: the app's Start on a paired Mac).
  /// `paired`: asked only for a `start` with `solo`, whether this Mac holds a pairing (`ClusterPairSummary.paired`).
  func validate(startsThePair: () throws -> Bool = { false }, paired: () -> Bool = { false }) throws {
    guard UUID(uuidString: id) != nil else { throw ValidationError("Invalid request ID") }
    guard Self.knownActions.contains(action) else { throw ValidationError("Unknown action") }
    try validateServingChoice(paired: paired)
    if ["start", "switch", "autopilot", "autopilot_pin", "autopilot_unpin"].contains(action) {
      let models = self.models ?? []
      // Only a plain start may name no models, where it starts the pair. `start --solo` names them, as every start
      // without a terminal must (`Start.requireModelsNamedWithoutTerminal`).
      let pairStart = try models.isEmpty && action == "start" && local != true && solo != true && startsThePair()
      guard !models.isEmpty || pairStart, models.count <= 32, Set(models).count == models.count
      else { throw ValidationError("Choose at least one model") }
      try models.forEach(Self.validateModel)
    }
    try validateFeatureFields()
    if action == "autopilot" {
      guard local != true, let pinned, Set(pinned).isSubset(of: Set(models ?? [])),
        Set(pinned).count == pinned.count
      else { throw ValidationError("Autopilot pins must be startup models") }
      try pinned.forEach(Self.validateModel)
      if let downloads {
        guard downloads.count <= 256, Set(downloads).count == downloads.count else {
          throw ValidationError("Invalid Autopilot downloads")
        }
        try downloads.forEach(Self.validateModel)
      }
    }
    if ["download", "remove"].contains(action) { try Self.validateModel(model ?? "") }
    if action == "settings" {
      guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        name.count <= 80,
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        let minutes = idle_minutes, minutes <= IdleUnloadPolicy.maxMinutes,
        auto_update != nil, revision != nil
      else { throw ValidationError("Invalid settings") }
    }
    if let schedule {
      guard schedule.windows.count <= 14 else { throw ValidationError("Too many schedule windows") }
      try schedule.validate()
    }
    if action == "cooling" {
      guard enabled != nil, (60...90).contains(speed ?? 70), (40...90).contains(temperature ?? 50)
      else { throw ValidationError("Invalid cooling policy") }
    }
  }

  static func validateModel(_ value: String) throws {
    guard !value.isEmpty, value.count <= 256, !value.hasPrefix("-"), !value.hasPrefix("/"),
      !value.contains(".."),
      value.unicodeScalars.allSatisfy({
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./"
        ).contains($0)
      })
    else { throw ValidationError("Invalid model ID") }
  }
}

struct DesktopOperation: Codable, Sendable {
  let id: String
  let action: String
  var state = "running"
  let started_at: Double
  var finished_at: Double?
  var message = "Working…"
  var cancellable: Bool
  var model: String?
  var progress: Double?
}
