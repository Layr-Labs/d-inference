import ArgumentParser
import Foundation
import ProviderCore

// Seams for the red tests of `darkbloom cluster leave`, with today's behaviour: no such command (leaving a pair is
// `cluster pair --status`, then `cluster pair --forget <pin>`), and `finishStop` ignores `leaving`.

extension Cluster {
    struct Leave: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "leave")
        @Flag(name: .shortAndLong) var yes = false
    }
}

struct ClusterLeaveFlow {
    var pair: ClusterPairSummary
    var pairing: ProviderUninstallPairing?
    var terminal: Bool
    var yes: Bool
    var ask: (String) -> String?
    var stopPart: () async throws -> ProviderUninstall.Outcome
    var forget: (String) throws -> Void
    var soloServing: () -> Bool
    var say: (String) -> Void

    func run() async -> Int32 { 1 }
}
