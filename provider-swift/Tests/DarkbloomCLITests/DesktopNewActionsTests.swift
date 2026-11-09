import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The actions the app gained for clusters, Darkbloom Sandbox, waitlists and local serving: each validates before
/// anything runs, and each argv parses as a real `darkbloom` command, with the API's `--config` exactly where the
/// command takes it.
struct DesktopNewActionsTests {
  static let config = "/tmp/desktop-new-actions-fixture.toml"
  static let model = "mlx-community/gpt-oss-20b-MXFP4-Q8"

  static func action(_ name: String, _ fill: (inout DesktopAction) -> Void = { _ in }) -> DesktopAction {
    var value = DesktopAction(id: UUID().uuidString, action: name)
    fill(&value)
    return value
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let action: DesktopAction
    let argv: [String]
    let forwardsConfig: Bool
    var testDescription: String { argv.joined(separator: " ") }
  }

  static let cases: [Case] = [
    Case(action: action("start") { $0.models = [model]; $0.network = true },
         argv: ["start", "--model", model, "--network"], forwardsConfig: true),
    Case(action: action("start") { $0.models = [model]; $0.endpoint = true },
         argv: ["start", "--model", model, "--local-endpoint"], forwardsConfig: true),
    Case(action: action("start") { $0.models = [model]; $0.solo = true },
         argv: ["start", "--solo", "--model", model], forwardsConfig: true),
    Case(action: action("start") { $0.models = [model, "mlx-community/Qwen3-8B-4bit"]; $0.solo = true; $0.endpoint = true },
         argv: ["start", "--solo", "--model", model, "--model", "mlx-community/Qwen3-8B-4bit", "--local-endpoint"],
         forwardsConfig: true),
    Case(action: action("start") { $0.models = [model]; $0.solo = true; $0.network = true },
         argv: ["start", "--solo", "--model", model, "--network"], forwardsConfig: true),
    Case(action: action("start") { $0.models = [model]; $0.solo = true; $0.local = true },
         argv: ["start", "--solo", "--model", model, "--local"], forwardsConfig: true),
    Case(action: action("cluster_leave"), argv: ["cluster", "leave", "--yes"], forwardsConfig: false),
    Case(action: action("sandbox_pause"), argv: ["sandbox", "pause"], forwardsConfig: false),
    Case(action: action("sandbox_resume"), argv: ["sandbox", "resume"], forwardsConfig: false),
    Case(action: action("sandbox_uninstall"), argv: ["sandbox", "uninstall", "--yes"], forwardsConfig: false),
    Case(action: action("route") { $0.route = "my-macs-first" }, argv: ["route", "my-macs-first"], forwardsConfig: true),
    Case(action: action("tool_setup") { $0.tool = "opencode" }, argv: ["start", "--opencode"], forwardsConfig: true),
    Case(action: action("tool_setup") { $0.tool = "hermes" }, argv: ["start", "--hermes"], forwardsConfig: true),
    Case(action: action("update_rollback"), argv: ["update", "--rollback", "--yes"], forwardsConfig: true),
  ]

  @Test(arguments: cases)
  func argumentsParseAsTheCLIAndForwardConfigOnlyWhereAccepted(_ item: Case) throws {
    try item.action.validate(paired: { true })
    let argv = try DesktopBackend.arguments(for: item.action, configPath: Self.config, localActive: false)
    _ = try Darkbloom.parseAsRoot(argv)
    #expect(argv == item.argv + (item.forwardsConfig ? ["--config", Self.config] : []))
    let withoutConfig = try DesktopBackend.arguments(for: item.action, configPath: nil, localActive: false)
    _ = try Darkbloom.parseAsRoot(withoutConfig)
    #expect(withoutConfig == item.argv)
  }

  struct Refusal: Sendable, CustomTestStringConvertible {
    let action: DesktopAction
    let message: String
    var paired = true
    var testDescription: String { "\(action.action): \(message)" }
  }

  static let refusals: [Refusal] = [
    Refusal(action: action("start") { $0.models = [model]; $0.local = true; $0.network = true },
            message: "Choose one way to serve: Only me, the Darkbloom network, or Both, me first."),
    Refusal(action: action("start") { $0.models = [model]; $0.endpoint = true; $0.network = true },
            message: "Choose one way to serve: Only me, the Darkbloom network, or Both, me first."),
    Refusal(action: action("start") { $0.models = [model]; $0.local = true; $0.endpoint = true },
            message: "Choose one way to serve: Only me, the Darkbloom network, or Both, me first."),
    Refusal(action: action("start") { $0.models = [model]; $0.solo = true },
            message: "This Mac isn't in a two-Mac cluster: Start serving serves it alone.", paired: false),
    Refusal(action: action("start") { $0.models = []; $0.solo = true }, message: "Choose at least one model"),
    Refusal(action: action("start") { $0.models = ["--force"]; $0.solo = true }, message: "Invalid model ID"),
    Refusal(action: action("switch") { $0.models = [model]; $0.solo = true },
            message: "Serving this Mac alone is a start, not a switch."),
    Refusal(action: action("start") { $0.models = []; $0.network = true },
            message: "Choose at least one model", paired: false),
    Refusal(action: action("waitlist_join") { $0.feature = "Sandbox" }, message: "Invalid waitlist"),
    Refusal(action: action("waitlist_join") { $0.feature = "-x" }, message: "Invalid waitlist"),
    Refusal(action: action("waitlist_join") { $0.feature = "sandbox\n" }, message: "Invalid waitlist"),
    Refusal(action: action("waitlist_join") { $0.feature = "sand box" }, message: "Invalid waitlist"),
    Refusal(action: action("waitlist_join") { $0.feature = String(repeating: "a", count: 65) },
            message: "Invalid waitlist"),
    Refusal(action: action("waitlist_join"), message: "Invalid waitlist"),
    Refusal(action: action("route") { $0.route = "everywhere" }, message: "Invalid route"),
    Refusal(action: action("local_settings") { $0.me_first = true; $0.me_first_idle_minutes = 0 },
            message: "Me first needs on or off, and 1 to 120 idle minutes."),
    Refusal(action: action("local_settings") { $0.me_first = true; $0.me_first_idle_minutes = 121 },
            message: "Me first needs on or off, and 1 to 120 idle minutes."),
    Refusal(action: action("local_settings") { $0.me_first_idle_minutes = 5 },
            message: "Me first needs on or off, and 1 to 120 idle minutes."),
    Refusal(action: action("tool_setup") { $0.tool = "vim" }, message: "Unknown tool"),
  ]

  @Test(arguments: refusals)
  func refusesBeforeAnythingRuns(_ item: Refusal) {
    let error = #expect(throws: ValidationError.self) { try item.action.validate(paired: { item.paired }) }
    #expect(error?.message == item.message)
  }

  @Test func waitlistNamesAreTheCatalogsIds() throws {
    for name in ["sandbox", "cluster", "a", "0-feature-2", String(repeating: "a", count: 64)] {
      try Self.action("waitlist_join") { $0.feature = name }.validate()
    }
  }

  @Test func aSoloStartNamesItsModelsAndNeverAsksWhetherThePairWouldStart() {
    let asked: () throws -> Bool = { throw ValidationError("asked about the pair") }
    #expect(throws: Never.self) {
      try Self.action("start") { $0.models = [Self.model]; $0.solo = true }.validate(
        startsThePair: asked, paired: { true })
    }
    let error = #expect(throws: ValidationError.self) {
      try Self.action("start") { $0.models = []; $0.solo = true }.validate(startsThePair: asked, paired: { true })
    }
    #expect(error?.message == "Choose at least one model")
  }

  @Test func localSettingsAcceptTheCLIRange() throws {
    for minutes: UInt64 in [1, 2, 120] {
      try Self.action("local_settings") { $0.me_first = false; $0.me_first_idle_minutes = minutes }.validate()
    }
  }
}
