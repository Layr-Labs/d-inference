import DarkbloomClusterRemote
import Foundation

extension ClusterIncidentLog {
    /// This build's incident log (`BuildEnvironment.current`).
    public static func forThisInstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                      redact: @escaping @Sendable (String) -> String = { $0 }) -> ClusterIncidentLog {
        ClusterIncidentLog(file: defaultFile(homeDirectory: homeDirectory), redact: redact, install: BuildEnvironment.current.rawValue)
    }
}
