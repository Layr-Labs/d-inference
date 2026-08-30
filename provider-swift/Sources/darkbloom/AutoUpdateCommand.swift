import ArgumentParser
import Foundation
import ProviderCore

struct AutoUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autoupdate",
        abstract: "Show coordinator-managed release rollout status.",
        discussion: """
        Process-evidence-v1 providers receive one coordinator-authorized target
        and generation. Local enable/disable switches cannot bypass or pause the
        fleet rollout. The legacy provider.auto_update key remains parseable for
        older installed providers only.
        """
    )

    @Argument(help: "Action: status")
    var action: String

    mutating func run() async throws {
        switch action.lowercased() {
        case "status":
            let record = try UpdateLifecycleStore().load()
            print("Release rollout is COORDINATOR MANAGED.")
            print("Lifecycle: \(record.state.rawValue)")
            if let command = record.command {
                print("Authorized target: v\(command.version) (generation \(command.desiredGeneration))")
            }

        case "enable", "on", "true", "disable", "off", "false":
            printError(
                "local auto-update toggles are retired for process-evidence-v1 providers; the coordinator is authoritative")
            throw ExitCode.failure

        default:
            printError("Unknown action: '\(action)'. Use 'status'.")
            throw ExitCode.failure
        }
    }
}
