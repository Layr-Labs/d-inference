import Foundation
import ProviderCore

/// The background service and the saved choice (`[local] mode`).
enum SavedChoiceService {
    struct Alignment: Equatable {
        /// How the job serves once restarted; nil without a job this build reads.
        var mode: LocalSettings.Mode?
        /// Says the job now serves the saved choice instead of another; nil when it already did.
        var line: String?
    }

    /// The installed job restarts as it is.
    static func align(configPath: String?, job: LaunchAgent.ServingJob? = LaunchAgent.installedServingJob(),
                      thisMacPort: (() throws -> UInt16)? = nil,
                      rewrite: (LocalSettings.Mode, UInt16, String, String) throws -> Bool = { _, _, _, _ in false })
        throws -> Alignment {
        Alignment(mode: job?.mode, line: nil)
    }
}
