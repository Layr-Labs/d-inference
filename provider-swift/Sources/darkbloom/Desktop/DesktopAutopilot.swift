import ArgumentParser
import Foundation
import ProviderCore

extension DesktopBackend {
  func runAutopilot(_ request: DesktopAction, arguments: [String], worker: DesktopWorker,
    beforeStart: @Sendable () async throws -> Void = {}) async throws -> (Int32, String) {
    for model in request.downloads ?? [] {
      try Task.checkCancellation()
      setDownloadModel(request.id, model: model)
      let (code, output) = try await worker.run(
        ["models", "download", model] + (configPath.map { ["--config", $0] } ?? []),
        progress: { [weak self] output in Task { await self?.setProgress(request.id, output: output, downloadModel: model) } })
      guard code == 0 else { throw ValidationError("Download failed for \(model): \(output)") }
    }
    try Task.checkCancellation()
    setDownloadModel(request.id, model: nil)
    try validateAutopilotPins(request.pinned ?? [])
    try await beforeStart()
    try Task.checkCancellation()
    var result = try await worker.run(arguments,
      progress: { [weak self] output in Task { await self?.setProgress(request.id, output: output) } })
    if result.0 == 0, let pinned = request.pinned, !pinned.isEmpty {
      try Task.checkCancellation()
      result = try await worker.run(Self.autopilotPinArguments(pinned, configPath: configPath))
    }
    return result
  }

  static func autopilotArguments(for request: DesktopAction, config: [String]) -> [String]? {
    switch request.action {
    case "autopilot":
      return ["start", "--autopilot"] + (request.models ?? []).flatMap { ["--model", $0] }
        + (request.endpoint == true ? ["--local-endpoint"] : []) + config
    case "autopilot_pin", "autopilot_unpin":
      return ["autopilot", request.action == "autopilot_pin" ? "pin" : "unpin"]
        + (request.models ?? []) + config
    case "autopilot_pause", "autopilot_resume", "autopilot_disable", "autopilot_models":
      return ["autopilot", String(request.action.dropFirst("autopilot_".count))] + config
    default: return nil
    }
  }

  static func autopilotPinArguments(_ models: [String], configPath: String?) -> [String] {
    ["autopilot", "pin"] + models + (configPath.map { ["--config", $0] } ?? [])
  }

  /// The CLI inventory wizard is interactive. Desktop uses its existing explicit
  /// startup selection path, which verifies cached inventory before safely draining.
  static func autopilotRefreshArguments(settings: ModelAutopilotSettings,
    startupModels: [String], endpoint: LocalEndpoint.Info?, configPath: String?) throws -> [String] {
    guard settings.hasConsent else { throw ValidationError("Turn on Autopilot first") }
    let models = startupModels.isEmpty ? Array(settings.selectedModels.prefix(1)) : startupModels
    guard !models.isEmpty else { throw ValidationError("Choose a startup model first") }
    try models.forEach(DesktopAction.validateModel)
    var arguments = ["start", "--autopilot"] + models.flatMap { ["--model", $0] }
    if let endpoint {
      arguments += ["--local-endpoint", "--port", String(endpoint.port), "--bind", endpoint.host]
      if endpoint.apiKey.isEmpty { arguments += ["--no-auth"] }
    }
    return arguments + (configPath.map { ["--config", $0] } ?? [])
  }

  func validateAutopilotPins(_ requested: [String]) throws {
    guard !requested.isEmpty else { return }
    let loaded = try configuration()
    let pins = Set(loaded.config.backend.modelAutopilot.pinnedModels + requested)
    guard pins.count <= loaded.config.backend.maxModelSlots else {
      throw ValidationError("These pins exceed this Mac’s model slot limit")
    }
    guard let hardware = loaded.hardware else { throw ValidationError("Cannot check this Mac’s memory") }
    ModelScanner.configureCacheDirectory(try ConfigManager.modelCacheDirectory(in: loaded.config, relativeTo: loaded.configPath))
    let local = ModelScanner.scanAllModels(hardwareInfo: hardware)
    let chosen = local.filter { pins.contains($0.id) }
    guard Set(chosen.map(\.id)) == pins else { throw ValidationError("Download every pinned model first") }
    guard chosen.reduce(0, { $0 + $1.estimatedMemoryGb }) <= Start.pickerLoadBudgetGiB(memoryGb: Double(hardware.memoryGb)) else {
      throw ValidationError("These pins exceed this Mac’s model memory allowance")
    }
  }

  static func autopilotSnapshot(_ settings: ModelAutopilotSettings, daemon: DaemonState?, fresh: Bool) -> JSONValue {
    .dict([
      "enabled": .bool(settings.hasConsent), "paused": .bool(settings.paused),
      "configured": .bool(settings.consentRecorded),
      "selected": .array(settings.selectedModels.map(DV.string)),
      "pinned": .array(settings.pinnedModels.map(DV.string)),
      "phase": fresh ? daemon?.autopilotPhase.map(DV.string) ?? .null : .null,
    ])
  }

  static func downloadProgress(_ output: String) -> Double? {
    guard let pattern = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%"#),
      let match = pattern.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
      let range = Range(match.range(at: 1), in: output), let percent = Double(output[range]),
      (0...100).contains(percent) else { return nil }
    return percent / 100
  }
}
