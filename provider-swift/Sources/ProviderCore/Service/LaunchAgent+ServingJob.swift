import Foundation

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

        /// The job of a `start` argv.
        public init?(arguments: [String]) {
            return nil
        }
    }

    /// The installed job.
    public static func installedServingJob(at path: URL = plistPath()) -> ServingJob? { nil }

    /// Rewrites the installed job's arguments to serve `mode`; nothing yet.
    @discardableResult
    public static func rewriteInstalledJob(serving mode: LocalSettings.Mode, port: UInt16, bind: String,
                                           coordinatorURL: String, at path: URL = plistPath()) throws -> Bool {
        false
    }
}
