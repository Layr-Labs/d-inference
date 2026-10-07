import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Every argv the desktop API builds must parse as a real `darkbloom` command,
/// and must carry the API's `--config` exactly when that command accepts it.
struct DesktopActionArgumentsTests {
  static let config = "/tmp/desktop-arguments-fixture.toml"
  static let model = "mlx-community/gpt-oss-20b-MXFP4-Q8"

  struct Case: Sendable, CustomTestStringConvertible {
    let action: DesktopAction
    let localActive: Bool
    let forwardsConfig: Bool
    var testDescription: String {
      "\(action.action)\(action.local == true ? " (local)" : "")\(localActive ? " [local owner]" : "")"
    }
  }

  static func action(_ name: String, _ fill: (inout DesktopAction) -> Void = { _ in }) -> DesktopAction
  {
    var value = DesktopAction(id: UUID().uuidString, action: name)
    fill(&value)
    return value
  }

  static let cases: [Case] = [false, true].flatMap { local in
    [
      Case(action: action("start") { $0.models = [model] }, localActive: local, forwardsConfig: true),
      Case(
        action: action("start") {
          $0.models = [model]
          $0.local = true
        }, localActive: local, forwardsConfig: true),
      Case(
        action: action("start") {
          $0.models = [model]
          $0.endpoint = true
        }, localActive: local, forwardsConfig: true),
      // `switch` reads the live provider's config; only the local-owner path takes one.
      Case(action: action("switch") { $0.models = [model] }, localActive: local, forwardsConfig: local),
      Case(action: action("stop"), localActive: local, forwardsConfig: local),
      Case(action: action("restart"), localActive: local, forwardsConfig: true),
      Case(action: action("update"), localActive: local, forwardsConfig: true),
      Case(action: action("diagnose"), localActive: local, forwardsConfig: true),
      Case(action: action("unlink"), localActive: local, forwardsConfig: false),
      Case(action: action("download") { $0.model = model }, localActive: local, forwardsConfig: true),
      Case(action: action("remove") { $0.model = model }, localActive: local, forwardsConfig: true),
      Case(action: action("autopilot") { $0.models = [model]; $0.pinned = [] }, localActive: local, forwardsConfig: true),
      Case(action: action("autopilot_pin") { $0.models = [model] }, localActive: local, forwardsConfig: true),
      Case(action: action("autopilot_unpin") { $0.models = [model] }, localActive: local, forwardsConfig: true),
      Case(action: action("autopilot_pause"), localActive: local, forwardsConfig: true),
      Case(action: action("autopilot_resume"), localActive: local, forwardsConfig: true),
      Case(action: action("autopilot_disable"), localActive: local, forwardsConfig: true),
      Case(action: action("autopilot_models"), localActive: local, forwardsConfig: true),
      Case(
        action: action("cooling") {
          $0.enabled = true
          $0.speed = 60
        }, localActive: local, forwardsConfig: false),
    ]
  }

  @Test(arguments: cases)
  func argumentsParseAndForwardConfigExactlyWhereAccepted(_ item: Case) throws {
    try item.action.validate()
    let argv = try DesktopBackend.arguments(
      for: item.action, configPath: Self.config, localActive: item.localActive)
    _ = try Darkbloom.parseAsRoot(argv)
    #expect(argv.contains("--config") == item.forwardsConfig, "\(argv)")
    if item.forwardsConfig { #expect(argv.suffix(2) == ["--config", Self.config]) }
  }

  @Test func withoutAConfigNoActionAddsTheFlag() throws {
    for item in Self.cases {
      let argv = try DesktopBackend.arguments(
        for: item.action, configPath: nil, localActive: item.localActive)
      _ = try Darkbloom.parseAsRoot(argv)
      #expect(!argv.contains("--config"), "\(argv)")
    }
  }

  @Test func restartForwardsTheDesktopConfig() async throws {
    let backend = DesktopBackend(configPath: Self.config)
    let argv = try await backend.arguments(for: Self.action("restart"))
    _ = try Darkbloom.parseAsRoot(argv)
    #expect(argv.suffix(2) == ["--config", Self.config])
  }

  @Test(arguments: ["stop-local", "restart-local"])
  func localLifecycleCommandsAcceptConfig(command: String) throws {
    _ = try Darkbloom.parseAsRoot(["desktop", command, "--config", Self.config])
  }

  @Test func refusesPinsOutsideStartupSelection() throws {
    let request = Self.action("autopilot") { $0.models = [Self.model]; $0.pinned = ["another-model"] }
    #expect(throws: (any Error).self) { try request.validate() }
  }

  @Test func pinFollowupUsesTheSameCLIAndConfig() throws {
    let argv = DesktopBackend.autopilotPinArguments([Self.model], configPath: Self.config)
    _ = try Darkbloom.parseAsRoot(argv)
    #expect(argv == ["autopilot", "pin", Self.model, "--config", Self.config])
  }

  @Test func refreshRetainsStartupAndEndpointWithoutAnInteractiveWizard() throws {
    let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
      selectedModels: [Self.model, "another-model"], revision: "test")
    let endpoint = LocalEndpoint.Info(host: "0.0.0.0", port: 7777, apiKey: "", version: "test", pid: 1, updatedAt: "test")
    let argv = try DesktopBackend.autopilotRefreshArguments(settings: settings,
      startupModels: [Self.model], endpoint: endpoint, configPath: Self.config)
    _ = try Darkbloom.parseAsRoot(argv)
    #expect(argv == ["start", "--autopilot", "--model", Self.model, "--local-endpoint", "--port", "7777", "--bind", "0.0.0.0", "--no-auth", "--config", Self.config])
    let fallback = try DesktopBackend.autopilotRefreshArguments(settings: settings,
      startupModels: [], endpoint: nil, configPath: nil)
    #expect(fallback == ["start", "--autopilot", "--model", Self.model])
    #expect(throws: (any Error).self) {
      try DesktopBackend.autopilotRefreshArguments(settings: ModelAutopilotSettings(),
        startupModels: [Self.model], endpoint: nil, configPath: nil)
    }
  }

  @Test func configuredEnrollmentDoesNotInventALivePhase() {
    let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
      selectedModels: [Self.model], revision: "test")
    let snapshot = DesktopBackend.autopilotSnapshot(settings, daemon: nil, fresh: false)
    #expect(snapshot.field("configured").flag == true)
    #expect(snapshot.field("enabled").flag == true)
    #expect(snapshot.field("phase") == .null)
    #expect(DesktopBackend.autopilotSnapshot(ModelAutopilotSettings(), daemon: nil, fresh: false).field("configured").flag == false)
  }

  @Test func progressUsesTheLatestValidDownloadPercentage() {
    #expect(DesktopBackend.downloadProgress("10%\nmodel 40.5%") == 0.405)
    #expect(DesktopBackend.downloadProgress("Downloaded 100%") == 1)
    #expect(DesktopBackend.downloadProgress("Loading weights" ) == nil)
    #expect(DesktopBackend.downloadProgress("Impossible 200%") == nil)
  }
}
