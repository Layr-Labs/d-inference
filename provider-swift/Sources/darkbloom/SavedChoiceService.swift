import Foundation
import ProviderCore

/// The background service always serves the saved choice (`[local] mode`). Before `restart` and `update` restart it,
/// a job that an earlier build or start left serving another way is rewritten to that choice, with the same models, on
/// this Mac's one port. Without a saved choice (a Mac updated from a build that had no `[local]`), nothing is rewritten:
/// the job restarts byte for byte as installed.
enum SavedChoiceService {
    struct Alignment: Equatable {
        /// How the job serves once restarted; nil without a job this build reads.
        var mode: LocalSettings.Mode?
        /// Says the job now serves the saved choice instead of another; nil when it already did.
        var line: String?
    }

    /// Restarts the drained provider service as saved: the job is aligned first (`align`), then launchd reloads it
    /// (`LaunchAgent.restartAfterDrain`). `restart` and `update` both end their drain here.
    static func restartAsSaved(configPath: String?) throws -> Alignment {
        let alignment = try align(configPath: configPath)
        try LaunchAgent.restartAfterDrain()
        return alignment
    }

    /// Rewrites the job installed at `plist` to the saved choice (`LaunchAgent.rewriteInstalledJob`) and says how it
    /// serves. Darkbloom network serves no local API, so no port is chosen, probed or saved for it.
    static func align(configPath: String?, plist: URL = LaunchAgent.plistPath(),
                      thisMacPort: (String?) throws -> UInt16 = SavedChoiceService.thisMacPort(configPath:))
        throws -> Alignment {
        guard let job = LaunchAgent.installedServingJob(at: plist) else { return Alignment(mode: nil, line: nil) }
        let config = try savedConfig(configPath: configPath)
        guard let saved = config?.local?.mode else { return Alignment(mode: job.mode, line: nil) }
        // The network job's arguments name no port: the one given for it is never used.
        let port = saved == .network ? job.port ?? LocalAPIPort.firstTried : try thisMacPort(configPath)
        let bind = config?.local?.bind ?? job.bind ?? LocalSettings.defaultBind
        let coordinator = config?.coordinator.url ?? BuildEnvironment.current.coordinatorWebSocketURL
        let rewritten = try LaunchAgent.rewriteInstalledJob(serving: saved, port: port, bind: bind,
                                                            coordinatorURL: coordinator, at: plist)
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
