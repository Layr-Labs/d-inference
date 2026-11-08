import Foundation

/// The single-Mac provider job as its arguments say it serves, and its rewrite to the saved choice: the background
/// service always serves `[local] mode`, so `restart` and `update` bring back that choice, never the way an earlier
/// build or start left the job.
extension LaunchAgent {
    /// What the installed single-Mac job serves, and with what.
    public struct ServingJob: Equatable, Sendable {
        public var binaryPath: String
        public var mode: LocalSettings.Mode
        public var models: [String]
        public var configPath: String?
        public var coordinatorURL: String?
        public var port: UInt16?
        public var bind: String?
        public var noAuth: Bool

        /// The job of a `start` argv; nil for a cluster member's or one this build doesn't read.
        public init?(arguments: [String]) {
            guard arguments.count >= 2, arguments[1] == "start", !LaunchAgent.isClusterMemberJob(arguments),
                  !arguments.contains("--distributed") else { return nil }
            func values(_ flag: String) -> [String] {
                arguments.indices.compactMap { arguments[$0] == flag && $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }
            binaryPath = arguments[0]
            mode = arguments.contains("--local") ? .local : arguments.contains("--local-endpoint") ? .both : .network
            models = values("--model")
            configPath = values("--config").last
            coordinatorURL = values("--coordinator-url").last
            port = values("--port").last.flatMap { UInt16($0) }
            bind = values("--bind").last
            noAuth = arguments.contains("--no-auth")
        }
    }

    /// The installed job; nil without one, or for a job `ServingJob` doesn't read.
    public static func installedServingJob(at path: URL = plistPath()) -> ServingJob? {
        guard let data = try? Data(contentsOf: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return ServingJob(arguments: arguments)
    }

    /// `job`'s arguments to serve `mode`, its local API on `port` and `bind`: the same binary, models, config and
    /// coordinator (`coordinatorURL` when it names none), as `start` writes them.
    public static func programArguments(for job: ServingJob, serving mode: LocalSettings.Mode, port: UInt16,
                                        bind: String, coordinatorURL: String) -> [String] {
        let configPath = job.configPath.map { URL(fileURLWithPath: $0) }
        guard mode != .local else {
            return localProgramArguments(binaryPath: job.binaryPath, models: job.models, configPath: configPath,
                                         port: port, bind: bind, noAuth: job.noAuth)
        }
        return serviceProgramArguments(
            binaryPath: job.binaryPath, coordinatorURL: job.coordinatorURL ?? coordinatorURL, models: job.models,
            configPath: configPath,
            localEndpoint: LocalEndpointOptions(enabled: mode == .both, port: port, bind: bind, noAuth: job.noAuth))
    }

    /// Rewrites the installed job's arguments to serve `mode`, keeping every other key of its plist; false when they
    /// already do, or without a job this build reads (nothing written). The caller restarts it.
    @discardableResult
    public static func rewriteInstalledJob(serving mode: LocalSettings.Mode, port: UInt16, bind: String,
                                           coordinatorURL: String, at path: URL = plistPath()) throws -> Bool {
        guard let data = try? Data(contentsOf: path),
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String], let job = ServingJob(arguments: arguments)
        else { return false }
        let wanted = programArguments(for: job, serving: mode, port: port, bind: bind, coordinatorURL: coordinatorURL)
        guard wanted != arguments else { return false }
        plist["ProgramArguments"] = wanted
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path, options: .atomic)
        return true
    }
}
