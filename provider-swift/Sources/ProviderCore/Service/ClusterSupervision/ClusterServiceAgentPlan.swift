import Foundation
import CryptoKit

/// The cluster service's login agent, as pure values (review finding 12: the
/// cluster did not come back by itself after a reboot because nothing started
/// this Mac's cluster service at login).
///
/// `darkbloom cluster` (on the leader and on every member) installs this
/// Mac's cluster service as a per-user LaunchAgent:
///
/// - launchd runs `darkbloom cluster service --supervise`: the S18 supervisor
///   (`ClusterMemberSupervisor`), which runs `darkbloom cluster service` as its
///   child and restarts it with the owner's restart budget and backoff
///   (`ClusterMemberRestartBudget`: 15 s doubling to 300 s, parked after three
///   quick failures), so launchd itself never spins a failing service;
/// - `RunAtLoad`: it starts at login, which on an auto-login Mac is at boot;
/// - `KeepAlive` on an unsuccessful exit, throttled by the budget's first
///   backoff: launchd brings back a supervisor that crashed, never one an
///   operator stopped (it exits 0);
/// - the label is scoped to the build (`BuildEnvironment.clusterServiceLabelPrefix`:
///   production's `io.darkbloom.cluster-service.`, DevNet's
///   `io.darkbloom.cluster-service.dev.`) and to the install (a digest of the
///   installed app, or of the directory of a development build), so two
///   installs never share a job, a newer location of the same build takes over
///   the older one's job, and one build never takes, stops or removes
///   another's (`isOwnAgent`);
/// - `darkbloom cluster stop` and unpairing (`darkbloom cluster pair --forget`)
///   remove it, so a stopped cluster stays stopped across reboots.
///
/// Installing asks for nothing: a per-user agent in the user's own launchd
/// domain needs no administrator approval (macOS shows its "background item
/// added" notice, as for the provider's own agent).
public enum ClusterServiceAgentPlan {
    /// This build's label prefix: production's `io.darkbloom.cluster-service.`.
    public static var labelPrefix: String { BuildEnvironment.current.clusterServiceLabelPrefix }

    /// The bundle or folder that identifies an install: `<X>.app` for a
    /// binary inside an app bundle (`Contents/MacOS` or `Contents/Helpers`),
    /// otherwise the folder holding the binary. `executablePath` is resolved
    /// (no symbolic links), as `LaunchctlControl.currentExecutablePath()` gives it.
    public static func installRoot(executablePath: String) -> String {
        let url = URL(fileURLWithPath: executablePath).standardizedFileURL
        let components = url.pathComponents
        // The outermost bundle: a helper app inside the app belongs to the same install.
        if let bundle = components.indices.first(where: {
            components[$0].hasSuffix(".app") && $0 + 1 < components.count && components[$0 + 1] == "Contents"
        }) {
            return NSString.path(withComponents: Array(components[...bundle]))
        }
        return url.deletingLastPathComponent().path
    }

    /// `<prefix><12 hex digits of SHA-256(install root)>`: production's `io.darkbloom.cluster-service.<12 hex>`.
    public static func label(executablePath: String, environment: BuildEnvironment = .current) -> String {
        let digest = SHA256.hash(data: Data(installRoot(executablePath: executablePath).utf8))
        return environment.clusterServiceLabelPrefix + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a LaunchAgents file name has the shape of `environment`'s cluster service agents: its prefix and 12
    /// lowercase hex digits. Production's prefix starts every other build's too, but their labels have more after
    /// it, so no other build's file has production's shape.
    public static func isAgentFileName(_ name: String, environment: BuildEnvironment = .current) -> Bool {
        let prefix = environment.clusterServiceLabelPrefix
        guard name.hasPrefix(prefix), name.hasSuffix(".plist") else { return false }
        let suffix = name.dropFirst(prefix.count).dropLast(".plist".count)
        return suffix.count == 12 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Whether the agent in `fileName`, whose job runs `program` (the plist's first program argument; nil when it
    /// can't be read), is `environment`'s own: what its `cluster stop --service`, unpairing, uninstall and the next
    /// `cluster` may stop, replace or remove. Production's shape is also what every build wrote before builds had
    /// prefixes of their own (0.10.9 and earlier): such a job is another build's when its program is in that build's
    /// folder (an older DevNet's `~/.darkbloom-dev/…/darkbloom-dev`), and production's otherwise, as before. Outside
    /// production, a job of production's shape is this build's only when its program is in this build's own folder.
    public static func isOwnAgent(fileName: String, program: String?, environment: BuildEnvironment = .current,
                                  home: URL) -> Bool {
        func inFolder(of install: BuildEnvironment) -> Bool {
            guard let program else { return false }
            let folder = canonical(install.installDirectory(home: home).path)
            return canonical(program).hasPrefix(folder + "/")
        }
        if isAgentFileName(fileName, environment: environment) {
            guard environment == .prod else { return true }
            return !BuildEnvironment.allCases.contains { $0 != .prod && inFolder(of: $0) }
        }
        return environment != .prod && isAgentFileName(fileName, environment: .prod) && inFolder(of: environment)
    }

    /// `path` with the links of its deepest existing folder resolved (`/var` reads `/private/var`), so a program
    /// that is gone and the folder it was in compare alike.
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/" {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
            }
            missing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The options `darkbloom cluster service` and its supervisor both take
    /// (the provider configuration and the worker), nothing else.
    public static func serviceOptions(config: String?, worker: String?) -> [String] {
        (config.map { ["--config", $0] } ?? []) + (worker.map { ["--worker", $0] } ?? [])
    }

    /// What launchd runs: the supervisor.
    public static func programArguments(executablePath: String, serviceOptions: [String]) -> [String] {
        [executablePath, "cluster", "service", "--supervise"] + serviceOptions
    }

    /// What the supervisor runs: the service itself, with the same options.
    public static func childArguments(serviceOptions: [String]) -> [String] {
        ["cluster", "service"] + serviceOptions
    }

    /// The service's own grace for this Mac's part (SIGTERM, then wait: a rank
    /// holding a model releases it itself), and launchd's allowance above it
    /// before it would send SIGKILL to the job at a bootout or logout.
    public static let partStopGraceSeconds = 300
    public static let exitTimeOutSeconds = partStopGraceSeconds + 60

    /// Environment the job carries. launchd does not inherit the installing
    /// shell: the provider's allowlist (`LaunchAgent.passthroughEnvironment`)
    /// is passed in, and a fixed home (`CFFIXED_USER_HOME`, set only where a
    /// host redirects the user's home) is kept so the service reads the same
    /// cluster files as the command that installed it.
    public static func environment(passthrough: [String: String], installing: [String: String]) -> [String: String] {
        var out = passthrough
        if let home = installing["CFFIXED_USER_HOME"], home.hasPrefix("/") { out["CFFIXED_USER_HOME"] = home }
        return out
    }

    /// The launchd property list for the job.
    public static func propertyList(label: String, programArguments: [String], logPath: String,
                                    environment: [String: String],
                                    bundleIdentifier: String? = nil,
                                    budget: ClusterMemberRestartBudget.Limits = .production) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            // Only a supervisor that crashed comes back; an operator stop exits 0.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": budget.initialBackoffSeconds,
            "ProcessType": "Interactive",
            "ExitTimeOut": exitTimeOutSeconds,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        // Attribute this per-user agent to its enclosing app for Local Network privacy.
        if let bundleIdentifier, !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plist["AssociatedBundleIdentifiers"] = [bundleIdentifier]
        }
        if !environment.isEmpty { plist["EnvironmentVariables"] = environment }
        return plist
    }

    /// The property list's bytes, stable for equal inputs (so an install can
    /// tell an unchanged job from one that must be replaced).
    public static func encoded(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// What an install does, from what it finds. Idempotent: running
    /// `darkbloom cluster` again changes nothing on a healthy Mac.
    public enum InstallAction: Equatable, Sendable {
        /// Write the job and load it (first install, or after a stop).
        case writeAndLoad
        /// The job changed (another binary or options): unload, rewrite, load.
        case replace
        /// The same job is loaded but its service is not running (parked after
        /// its restart budget, or between restarts): restart it now, which also
        /// resets the budget.
        case restart
        /// The same job is loaded and its service runs.
        case nothing
    }

    public static func installAction(existing: Data?, desired: Data, loaded: Bool, serviceRunning: Bool) -> InstallAction {
        guard let existing else { return loaded ? .replace : .writeAndLoad }
        guard existing == desired else { return .replace }
        guard loaded else { return .writeAndLoad }
        return serviceRunning ? .nothing : .restart
    }

    /// Whether `launchctl print-disabled` lists this label as disabled
    /// (`"<label>" => disabled` or `=> true`); a disabled job cannot be loaded.
    public static func isDisabled(label: String, printDisabledOutput: String) -> Bool {
        printDisabledOutput.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\"\(label)\"") else { return false }
            return text.hasSuffix("=> disabled") || text.hasSuffix("=> true")
        }
    }

    /// `darkbloom status` lines for the cluster service. `agents`: the
    /// installed login agents (label, loaded). `supervisor`: the supervisor's
    /// last state, used only when written in this boot. Nothing at all on a
    /// Mac that is not part of a cluster.
    public static func statusLines(agents: [(label: String, loaded: Bool)], serviceRunning: Bool, paired: Bool,
                                   supervisor: ClusterMemberSupervisorState?, now: Double, bootTime: Double) -> [String] {
        guard let agent = agents.first else {
            if serviceRunning {
                return ["Cluster service: running, but not set to start at login (run `darkbloom cluster` to set that up)"]
            }
            return paired ? ["Cluster service: not running and not set to start at login (run `darkbloom cluster`)"] : []
        }
        let state: String
        if !agent.loaded { state = "set to start at login but not loaded now (run `darkbloom cluster`)" }
        else if serviceRunning { state = "running; starts at login" }
        else { state = "starts at login; not running now" }
        var lines = ["Cluster service: \(state) (launchd \(agent.label))"]
        if agents.count > 1 {
            lines.append("  also installed: \(agents.dropFirst().map(\.label).joined(separator: ", ")) (`darkbloom cluster` keeps one)")
        }
        if agent.loaded, let supervisor, abs(supervisor.bootTime - bootTime) < 60 {
            lines.append("  " + supervisor.summary(now: now, name: "supervisor"))
        }
        return lines
    }
}
