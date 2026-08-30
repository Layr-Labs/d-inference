import ArgumentParser
import Foundation
import ProviderCore

private func updateConfigReadFailureIsMissing(_ error: Error) -> Bool {
    let nsError = error as NSError
    return (nsError.domain == NSCocoaErrorDomain
        && nsError.code == CocoaError.Code.fileNoSuchFile.rawValue)
        || (nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.ENOENT.rawValue))
}

func loadUpdateConfig(configPath: String?) throws -> ProviderConfig {
    do {
        return try loadRuntimeSnapshot(configPath: configPath).config
    } catch ConfigError.readFailed(_, let underlying)
        where updateConfigReadFailureIsMissing(underlying)
    {
        return ConfigManager.loadDefault()
    }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Inspect or resume a coordinator-authorized provider update."
    )

    @Flag(help: "Show coordinator-authorized update state without taking action.")
    var checkOnly = false

    mutating func run() async throws {
        print("darkbloom update")
        print("Current version: \(ProviderCore.version)")
        print("")

        let store = UpdateLifecycleStore()
        let record: UpdateLifecycleRecord
        do {
            record = try store.load()
        } catch {
            printError("update lifecycle state is unreadable; refusing unsafe manual update")
            throw ExitCode.failure
        }

        if checkOnly {
            print("Coordinator-managed lifecycle: \(record.state.rawValue)")
            if let command = record.command {
                print("Authorized target: v\(command.version) (generation \(command.desiredGeneration))")
            } else {
                print("No release is currently authorized for this provider.")
            }
            return
        }

        let providerRunning = ProcessLifecycle.providerIsRunning()
            || LaunchAgent.launchSnapshot()?.process != nil
        switch ManualUpdatePolicy.decide(
            providerRunning: providerRunning,
            record: record
        ) {
        case .refuseLiveProvider:
            printError(
                "refusing manual live update: the serving provider accepts only its coordinator-authorized release_update path")
            throw ExitCode.failure

        case .noCoordinatorAuthorization:
            printError(
                "no coordinator-authorized release_update is pending; this provider never polls or self-selects a release")
            throw ExitCode.failure

        case .resumeCoordinatorAuthorization(let command):
            print("Authorized target: v\(command.version) (generation \(command.desiredGeneration))")
            if LaunchAgent.isAnySupportedLabelLoaded() {
                print("Requesting the stopped provider to resume its authorized update...")
                try LaunchAgent.kickstartIfLoaded()
            } else {
                print("Provider is stopped. Start it to resume the authorized update.")
            }
        }
    }
}
