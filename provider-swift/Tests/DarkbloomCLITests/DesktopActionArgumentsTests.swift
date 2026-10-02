import ArgumentParser
import Foundation
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
}
