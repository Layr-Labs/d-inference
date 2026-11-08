import Foundation
import ProviderCore

extension Start {
    /// Where Only me serves: in this process, in the terminal that starts it.
    static func servesOnlyMeHere(here: Bool, foreground: Bool) -> Bool { true }

    /// Without a terminal: the models Only me serves.
    static func onlyMeModelsWithoutAsking(lastSelection: [String], onThisMac: [String]) -> [String] { [] }

    /// What an Only me start stops.
    static func onlyMeReplacesLine(_ state: DaemonState?,
                                   alive: (Int32) -> Bool = { daemonProcessAlive(pid: $0) }) -> String? {
        nil
    }

    /// What a start that set Only me up in the background says.
    static func onlyMeServiceSummary(models: [String], idleMinutes: UInt64, serving: StartServing, autoRestart: Bool,
                                     autoUpdate: Bool) -> [String] {
        []
    }
}
