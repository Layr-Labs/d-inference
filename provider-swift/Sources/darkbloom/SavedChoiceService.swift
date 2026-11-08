import Foundation
import ProviderCore

/// The background service always serves the saved choice (`[local] mode`). Before `restart` and `update` restart it,
/// a job that an earlier build or start left serving another way is rewritten to that choice, with the same models, on
/// this Mac's one port. Without a saved choice it restarts as installed, as before.
enum SavedChoiceService {
    struct Alignment: Equatable {
        /// How the job serves once restarted; nil without a job this build reads.
        var mode: LocalSettings.Mode?
        /// Says the job now serves the saved choice instead of another; nil when it already did.
        var line: String?
    }

    /// Rewrites the installed job to the saved choice (`LaunchAgent.rewriteInstalledJob`) and says how it serves.
    static func align(configPath: String?, job: LaunchAgent.ServingJob? = LaunchAgent.installedServingJob(),
                      thisMacPort: (() throws -> UInt16)? = nil,
                      rewrite: (LocalSettings.Mode, UInt16, String, String) throws -> Bool = {
                          try LaunchAgent.rewriteInstalledJob(serving: $0, port: $1, bind: $2, coordinatorURL: $3)
                      }) throws -> Alignment {
        guard let job else { return Alignment(mode: nil, line: nil) }
        let config = try savedConfig(configPath: configPath)
        guard let saved = config?.local?.mode else { return Alignment(mode: job.mode, line: nil) }
        let port = saved == .network ? job.port ?? LocalAPIPort.firstTried
            : try thisMacPort?() ?? Self.thisMacPort(configPath: configPath)
        let bind = config?.local?.bind ?? job.bind ?? LocalSettings.defaultBind
        let coordinator = config?.coordinator.url ?? BuildEnvironment.current.coordinatorWebSocketURL
        let rewritten = try rewrite(saved, port, bind, coordinator)
        guard rewritten, saved != job.mode else { return Alignment(mode: saved, line: nil) }
        return Alignment(mode: saved, line: "Restarting as saved: \(LocalFirstWords.choice(saved)) (the service was "
            + "set up for \(LocalFirstWords.choice(job.mode, article: true))).")
    }

    /// This Mac's one local API port (`LocalAPIPort.thisMac`), with the config at `configPath`.
    static func thisMacPort(configPath: String?) throws -> UInt16 {
        let loaded = try loadRuntimeConfiguration(configPath: configPath)
        return try LocalAPIPort.thisMac(configPath: loaded.configPath, fallbackConfig: loaded.config).port
    }
}
