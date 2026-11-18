import ArgumentParser
import Foundation
import ProviderCore

extension Start {
    /// Whether this build refuses network serving in a process the provider's
    /// launchd service did not start. Debug builds (tests, development) serve
    /// from a terminal as before.
    static var enforcesServiceLaunch: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// What a refused start says, or nil when it may serve the network.
    static func serviceLaunchRefusal(_ verdict: ServiceLaunchCheck.Verdict) -> [String]? {
        guard case .refuse(let refusal) = verdict else { return nil }
        let cli = BuildEnvironment.current.cliName
        let why = switch refusal {
        case .startedByAnotherProgram: "another program started it"
        case .adopted: "the program that started it has exited"
        case .notTheProviderJob: "launchd started it, but not as Darkbloom's service"
        case .unknown: "macOS did not report how it was started"
        }
        return ["\(cli): this copy does not serve the network: only Darkbloom's background service does (\(why)).",
                "Start the service with `\(cli) start`; to serve only this Mac in this terminal, run `\(cli) start --local --here`."]
    }

    /// Before network serving starts (provider, always-on member supervisor,
    /// cluster member): a release build refuses unless the provider's launchd
    /// service started this process (`ServiceLaunchCheck`), asks launchd to
    /// start the provider's service instead, and exits.
    static func requireServiceLaunch(
        enforced: Bool = Start.enforcesServiceLaunch,
        verdict: () -> ServiceLaunchCheck.Verdict = { ServiceLaunchCheck.live() },
        startService: () -> Bool = ServiceLaunchCheck.startProviderJob
    ) throws {
        guard enforced, let lines = serviceLaunchRefusal(verdict()) else { return }
        for line in lines { printError(line) }
        printError(startService()
            ? "Asked launchd to start Darkbloom's service if it isn't running."
            : "Darkbloom's service is not installed here; `\(BuildEnvironment.current.cliName) start` installs it.")
        throw ExitCode.failure
    }
}
