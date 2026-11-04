import DarkbloomClusterRemote
import Foundation

extension ClusterIncidentLog {
    /// This build's incident log (`BuildEnvironment.current`): production's `~/.darkbloom/cluster/incidents.json`, or
    /// the install's own file (`incidents.dev.json`), its records stamped and read with the install. Every reader and
    /// writer of this build's incidents opens it here.
    public static func forThisInstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                      redact: @escaping @Sendable (String) -> String = { $0 }) -> ClusterIncidentLog {
        let install = BuildEnvironment.current.rawValue
        return ClusterIncidentLog(file: defaultFile(homeDirectory: homeDirectory, install: install), redact: redact, install: install)
    }
}
