import Foundation
import ProviderCore

struct DesktopAccountSession {
  private var credential: String?
  private(set) var revision = UUID().uuidString
  mutating func observe(_ token: String?) -> String {
    if credential != token { credential = token; revision = UUID().uuidString }
    return revision
  }
}

extension DesktopBackend {
  static func modelActivity(_ capacity: DaemonState.Capacity?, fresh: Bool, now: Double) -> JSONValue {
    guard fresh, let observed = capacity?.activityObservedAt, now - observed <= 10,
      let models = capacity?.modelActivity else { return .null }
    return .array(models.map {
      .dict(["model": .string($0.model), "state": .string($0.state),
             "running": .int(Int64($0.running)), "waiting": .int(Int64($0.waiting))])
    })
  }
}
