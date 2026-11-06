import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Installs, restarts and removes this Mac's cluster service login agent
/// (`ClusterServiceAgentPlan` holds the job's shape and the decisions).
/// Only the user's own launchd domain (`gui/<uid>`) and the user's own
/// `~/Library/LaunchAgents` are touched; nothing needs an administrator.
public enum ClusterServiceAgent {
    public struct Job: Sendable, Equatable {
        public let label: String
        public let programArguments: [String]
        public let logPath: String
        public let environment: [String: String]
        /// The property list's bytes.
        public let plist: Data
    }

    /// The job for the darkbloom at `executablePath` (resolved) with the service options.
    public static func job(executablePath: String, serviceOptions: [String], logPath: URL,
                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Job {
        let label = ClusterServiceAgentPlan.label(executablePath: executablePath)
        let arguments = ClusterServiceAgentPlan.programArguments(executablePath: executablePath, serviceOptions: serviceOptions)
        let jobEnvironment = ClusterServiceAgentPlan.environment(
            passthrough: LaunchAgent.passthroughEnvironment(from: environment), installing: environment)
        let plist = try ClusterServiceAgentPlan.encoded(ClusterServiceAgentPlan.propertyList(
            label: label, programArguments: arguments, logPath: logPath.path, environment: jobEnvironment,
            bundleIdentifier: enclosingAppIdentifier(executablePath: executablePath)))
        return Job(label: label, programArguments: arguments, logPath: logPath.path, environment: jobEnvironment, plist: plist)
    }

    /// Only the actual enclosing app may be responsible for this executable.
    /// A bare tool cannot borrow an unrelated app's identity or its approvals.
    private static func enclosingAppIdentifier(executablePath: String) -> String? {
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        guard let bundle = ClusterMemberPermissionIdentity.enclosingAppBundle(of: executable.path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleExecutable"] as? String == executable.lastPathComponent else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    // MARK: - Paths and queries

    public static func launchAgentsDirectory() -> URL {
        LaunchctlControl.homeDirectory().appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static func plistPath(label: String) -> URL {
        launchAgentsDirectory().appendingPathComponent("\(label).plist")
    }

    /// This build's own cluster service agents installed for this user, by label (`ClusterServiceAgentPlan.isOwnAgent`):
    /// another build's agent (production's, beside DevNet) is never listed, so nothing here starts, stops or
    /// removes it.
    public static func installedLabels(environment: BuildEnvironment = .current) -> [String] {
        let directory = launchAgentsDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in
            guard name.hasSuffix(".plist") else { return false }
            return ClusterServiceAgentPlan.isOwnAgent(fileName: name, program: program(of: directory.appendingPathComponent(name)),
                                                      environment: environment, home: LaunchctlControl.homeDirectory())
        }.map { String($0.dropLast(".plist".count)) }.sorted()
    }

    /// The program a launch agent file runs (its first program argument), nil when it can't be read.
    static func program(of plist: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: plist.path),
              let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (job["ProgramArguments"] as? [String])?.first
    }

    public static func isLoaded(label: String) -> Bool {
        LaunchctlControl.printSucceeds(label: label)
    }

    /// The supervisor's state and the service's heartbeat, beside the service's own files.
    public static func supervisorStatePath(serviceDirectory: URL) -> URL {
        serviceDirectory.appendingPathComponent("service-supervisor.json")
    }

    public static func healthPath(serviceDirectory: URL) -> URL {
        serviceDirectory.appendingPathComponent("service-health.json")
    }

    /// The heartbeat of the service's coordinator-paired part: a file of its own, never the service's
    /// (`ClusterService.partEnvironment`).
    public static func partHealthPath(serviceDirectory: URL) -> URL {
        serviceDirectory.appendingPathComponent("part-health.json")
    }

    /// The supervisor's progress in the pair's coordinated update, which the service reports to the other Mac
    /// (`ClusterPairUpdateProgress`).
    public static func updateProgressPath(serviceDirectory: URL) -> URL {
        serviceDirectory.appendingPathComponent("service-update.json")
    }

    /// `darkbloom update`'s request to restart into the release it installed (`ClusterPairUpdate.Request`).
    public static func updateRequestPath(serviceDirectory: URL) -> URL {
        serviceDirectory.appendingPathComponent("service-update-request.json")
    }

    // MARK: - Install

    public enum Outcome: String, Sendable, Equatable {
        case installed, replaced, restarted, unchanged
    }

    /// Installs (or keeps) the job and leaves it running. Idempotent.
    ///
    /// - `serviceRunning`: whether a cluster service holds this home's lock now.
    /// - `stopUnsupervisedService`: ends a service an earlier version started
    ///   detached from a terminal (not under launchd), which would otherwise
    ///   keep the lock the supervised one needs; called only when the job is
    ///   not loaded and a service runs.
    @discardableResult
    public static func install(_ job: Job, serviceRunning: () -> Bool, stopUnsupervisedService: () throws -> Void,
                               environment: BuildEnvironment = .current) throws -> Outcome {
        // One cluster service per user and build: this build's other agents (an older app location, a development
        // build, the label an older build of it used) give way to this one. Another build's agent stays.
        for other in installedLabels(environment: environment) where other != job.label {
            try remove(label: other)
        }
        let path = plistPath(label: job.label)
        let existing = try? Data(contentsOf: path)
        let loaded = isLoaded(label: job.label)
        let action = ClusterServiceAgentPlan.installAction(existing: existing, desired: job.plist, loaded: loaded,
                                                           serviceRunning: serviceRunning())
        switch action {
        case .nothing:
            return .unchanged
        case .restart:
            try kickstart(label: job.label, kill: true)
            return .restarted
        case .writeAndLoad, .replace:
            if loaded { try bootout(label: job.label) }
            if serviceRunning() { try stopUnsupervisedService() }
            try write(job, to: path)
            try load(label: job.label, path: path)
            return action == .replace ? .replaced : .installed
        }
    }

    // MARK: - Remove

    /// Unloads and deletes every cluster service agent of this build (the
    /// service stops this Mac's part first, within the job's exit allowance),
    /// so nothing of it starts at the next login. Another build's agent stays
    /// loaded. Returns the labels removed.
    @discardableResult
    public static func uninstall(alsoLabel current: String? = nil, environment: BuildEnvironment = .current) throws -> [String] {
        var labels = installedLabels(environment: environment)
        if let current, !labels.contains(current), isLoaded(label: current) { labels.append(current) }
        for label in labels { try remove(label: label) }
        return labels
    }

    static func remove(label: String) throws {
        if isLoaded(label: label) { try bootout(label: label) }
        let path = plistPath(label: label)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    // MARK: - launchctl

    private static func write(_ job: Job, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try job.plist.write(to: path, options: .atomic)
    }

    private static func load(label: String, path: URL) throws {
        // A job left disabled (by hand, or by an older stop) cannot be bootstrapped;
        // enable only then, so an install leaves no override behind otherwise.
        let disabled = LaunchctlControl.run(["print-disabled", LaunchctlControl.guiDomain()], captureStdout: true)
        if ClusterServiceAgentPlan.isDisabled(label: label, printDisabledOutput: disabled.stdout) {
            let enabled = LaunchctlControl.setEnabled(true, label: label)
            guard enabled.succeeded else { throw LaunchAgentError.bootstrapFailed(enabled.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let bootstrap = try LaunchctlControl.runThrowing(["bootstrap", LaunchctlControl.guiDomain(), path.path], captureStderr: true)
        if !bootstrap.succeeded, !bootstrap.stderr.contains("already loaded") {
            throw LaunchAgentError.bootstrapFailed(bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // RunAtLoad starts it; a plain kickstart is a no-op when it already runs.
        try kickstart(label: label, kill: false)
    }

    private static func kickstart(label: String, kill: Bool) throws {
        let result = try LaunchctlControl.runThrowing(
            ["kickstart"] + (kill ? ["-k"] : []) + [LaunchctlControl.target(label: label)], captureStderr: true)
        if !result.succeeded {
            throw LaunchAgentError.kickstartFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// `bootout`, then wait until launchd no longer has the job: launchd sends
    /// SIGTERM, the supervisor forwards it, and the service stops this Mac's
    /// part (a rank holding a model releases it) within the job's ExitTimeOut.
    private static func bootout(label: String) throws {
        let result = try LaunchctlControl.runThrowing(["bootout", LaunchctlControl.target(label: label)], captureStderr: true)
        if !result.succeeded, !result.stderr.contains("could not find service"), !result.stderr.contains("3:") {
            throw LaunchAgentError.bootoutFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let deadline = LaunchctlControl.uptime() + Double(ClusterServiceAgentPlan.exitTimeOutSeconds)
        while LaunchctlControl.printSucceeds(label: label) {
            guard LaunchctlControl.uptime() < deadline else {
                throw LaunchAgentError.bootoutFailed("the cluster service did not stop within \(ClusterServiceAgentPlan.exitTimeOutSeconds) s")
            }
            LaunchctlControl.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - Status

    public struct Status: Sendable, Equatable {
        public let label: String
        public let installed: Bool
        public let loaded: Bool
    }

    /// Whether the cluster service running with `environment` starts by itself at login, as that process can tell
    /// without launchctl: it runs under its login agent's supervisor, which launchd starts at login
    /// (`ClusterSupervisionFiles.healthPathEnvironmentKey`), and that agent is still installed.
    public static func startsAtLogin(environment: [String: String], installedAgents: () -> [String]) -> Bool {
        environment[ClusterSupervisionFiles.healthPathEnvironmentKey] != nil && !installedAgents().isEmpty
    }

    public static func status(environment: BuildEnvironment = .current) -> [Status] {
        installedLabels(environment: environment).map { Status(label: $0, installed: true, loaded: isLoaded(label: $0)) }
    }
}
