import Foundation
import ProviderCore

extension DesktopBackend {
  /// Rapid or concurrent reads share one `fan status` child for ten seconds.
  func cooling() async -> JSONValue {
    if let coolingRead, coolingReadAt.map({ Date().timeIntervalSince($0) < 10 }) ?? true {
      return await coolingRead.value
    }
    let task = Task { [executable] in await Self.readCooling(executable: executable) }
    coolingRead = task
    coolingReadAt = nil
    let value = await task.value
    if coolingRead == task { coolingReadAt = Date() }
    return value
  }

  /// A finished cooling change makes the cached `fan status` stale, so the
  /// app's refresh after the action shows the new mode.
  func operationFinished(_ action: String) {
    guard action == "cooling" else { return }
    coolingRead = nil
    coolingReadAt = nil
  }

  static func readCooling(executable: URL?) async -> JSONValue {
    let signed = executable ?? (try? DesktopFanRuntime.resolve())
    guard
      let (code, output) = try? await DesktopWorker(executable: signed ?? executable).run(
        ["fan", "status", "--json"], timeout: 15),
      code == 0, let data = output.data(using: .utf8),
      let status = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      return .dict([
        "supported": .bool(false), "mode": .string("unavailable"), "fans": .array([]),
        "error": .string("Cooling status unavailable"),
      ])
    }
    return Self.projectCooling(status, controlAvailable: signed != nil)
  }

  static func projectCooling(_ status: JSONValue, controlAvailable: Bool) -> JSONValue {
    let diagnostic = status.field("diagnostic")
    let temperatures = diagnostic.field("gpuTemperatures").values.compactMap {
      $0.field("celsius").number
    }
    let fans = diagnostic.field("fans").values.map { fan in
      DV.dict([
        "name": fan.field("name").text.map(DV.string) ?? .string("Fan"),
        "rpm": fan.field("actualRPM"), "max_rpm": fan.field("maximumRPM"),
      ])
    }
    // Automatic describes the current SMC mode, including an enabled helper below its
    // trigger. The opt-in is on while the installed helper is loaded and reporting status.
    let enabled: JSONValue
    if status.field("helperError").text != nil { enabled = .null }
    else if status.field("loaded").flag == false { enabled = .bool(false) }
    else if status.field("loaded").flag == true, status.field("helper").field("mode").text != nil { enabled = .bool(true) }
    else { enabled = .null }
    return .dict([
      "supported": diagnostic.field("supported"),
      "control_available": .bool(controlAvailable),
      "enabled": enabled, "observed_at": .number(Date().timeIntervalSince1970),
      "speed": status.field("helper").field("speedPercent"),
      "threshold": status.field("helper").field("triggerTemperatureC"),
      "mode": status.field("helper").field("mode").text.map(DV.string)
        ?? .string(status.field("helperError").text == nil ? "automatic" : "unavailable"),
      "error": status.field("helperError"),
      "temperature": .number(temperatures.max()), "fans": .array(fans),
    ])
  }
}
