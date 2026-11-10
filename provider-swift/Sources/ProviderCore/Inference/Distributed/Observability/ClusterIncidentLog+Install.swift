import DarkbloomClusterRemote
import Foundation

extension ClusterIncidentLog {
    /// This build's incident log (`BuildEnvironment.current`), in its own folder: production's
    /// `~/.darkbloom/cluster/incidents.json`, DevNet's `~/.darkbloom-dev/cluster/incidents.dev.json`, its records
    /// stamped and read with the install. Every reader and writer of this build's incidents opens it here.
    public static func forThisInstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                      redact: @escaping @Sendable (String) -> String = { $0 }) -> ClusterIncidentLog {
        let environment = BuildEnvironment.current
        return ClusterIncidentLog(file: defaultFile(installDirectory: environment.installDirectory(home: homeDirectory),
                                                    install: environment.rawValue),
                                  redact: redact, install: environment.rawValue)
    }
}
