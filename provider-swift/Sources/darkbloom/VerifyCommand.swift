import ArgumentParser
import Foundation
import ProviderCore

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify the local provider install and coordinator trust state.",
        discussion: "Equivalent to a strict doctor run. Any warning or failure exits non-zero."
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator HTTP/WS URL for network verification.")
    var coordinator: String?

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        var checks = buildDoctorChecks(snapshot: snapshot)
        checks.append(contentsOf: await buildCoordinatorDoctorChecks(
            snapshot: snapshot,
            coordinatorOverride: coordinator
        ))

        print("darkbloom verify")
        print("Config: \(describeConfigPath(snapshot))")
        for check in checks {
            print("\(check.status.marker) \(check.name): \(check.detail)")
        }

        if checks.contains(where: { $0.status != .pass }) {
            throw ExitCode.failure
        }
    }
}
