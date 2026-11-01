import Foundation
import ArgumentParser
import ProviderCore

extension Start {
    /// The provider configuration path the cluster-member modes read.
    func clusterMemberConfigurationPath() throws -> URL {
        try configOptions.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ConfigManager.defaultConfigPath()
    }

    /// `darkbloom start --cluster-member --always-on`: install the member as
    /// the provider's launchd service, like a solo `darkbloom start`. launchd
    /// runs the supervisor (`--supervise`) at login and after reboots; the
    /// watchdog recovers the supervisor itself if it ever dies.
    func installClusterMemberService() async throws {
        let path = try clusterMemberConfigurationPath()
        // Refuse here, not in the background: a member with no saved setup
        // could only fail and exhaust its restart budget.
        _ = try DistributedStartSessionFactory(providerConfiguration: path)
        guard let setup = try ClusterMemberSupervisionSetup.load(providerConfiguration: path) else {
            throw ValidationError("No saved cluster setup in \(path.path); run `darkbloom cluster` on both Macs to pair them again.")
        }
        let config = try ConfigManager.load(from: path)
        let effectiveCoordinator = coordinatorURL ?? config.coordinator.url
        let replacement = try await ServiceDrain.prepare(options: drain)
        defer { replacement.release() }
        try await ServiceDrain.stopDrainedProvider()
        try LaunchAgent.installAndStart(coordinatorURL: effectiveCoordinator,
                                        configPath: configOptions.config == nil ? nil : path,
                                        clusterMember: true)
        let autoRestartOn = config.provider.autoRestart
        switch WatchdogAgent.rearmAction(autoRestartEnabled: autoRestartOn, isLoaded: WatchdogAgent.isLoaded()) {
        case .arm:
            do { try WatchdogAgent.installAndStart(configPath: path) } catch {
                printError("note: could not install crash-recovery watchdog: \(error)")
            }
        case .disarm:
            try? WatchdogAgent.stop()
        case nil:
            break
        }
        let limits = ClusterMemberRestartBudget.Limits.production
        print("Cluster member started as an always-on background service (\(setup.role), link \(setup.linkDevice)).")
        print("  It waits for the cluster link before registering, restarts the member with backoff")
        print("  (\(limits.initialBackoffSeconds)-\(limits.maxBackoffSeconds) s; stops after \(limits.maxQuickFailures) failures"
            + " that each lasted under \(Int(limits.quickFailureWindowSeconds)) s) and starts again at login.")
        print("  Updates are coordinated: both members drain and update at the cluster's update slot.")
        let identity = ClusterMemberPermissionIdentity.current(executablePath: Self.currentExecutablePath())
        if identity.verdict == .askedOnce {
            print("  Permissions: macOS asks once for Local Network on this Mac; click Allow when it appears.")
        } else {
            print("  Permissions: macOS will not ask once for this build:")
            for problem in identity.problems { print("    - \(problem)") }
            print("    Install the signed Darkbloom release for an always-on member.")
        }
        print("  Logs:    \(LaunchAgent.logPath().path)")
        print()
        print("  darkbloom stop     Stop the member (and keep it stopped across reboots)")
        print("  darkbloom restart  Restart it (also resets a spent restart budget)")
        print("  darkbloom status   Check status")
    }

    /// `--cluster-member --supervise`: the supervisor in this process.
    func runClusterMemberSupervisor() async throws {
        let path = try clusterMemberConfigurationPath()
        let setup = try ClusterMemberSupervisionSetup.load(providerConfiguration: path)
        let config = try ConfigManager.load(from: path)
        let environment = ProcessInfo.processInfo.environment
        var childArguments = ["start", "--foreground", "--cluster-member"]
        if configOptions.config != nil { childArguments += ["--config", path.path] }
        if let coordinatorURL { childArguments += ["--coordinator-url", coordinatorURL] }
        let executable = Self.currentExecutablePath()
        let supervisor = ClusterMemberSupervisor(configuration: .init(
            executable: executable,
            childArguments: childArguments,
            environment: environment,
            statePath: ClusterSupervisionFiles.statePath(environment: environment),
            healthPath: environment[ClusterSupervisionFiles.healthPathEnvironmentKey].map { URL(fileURLWithPath: $0) }
                ?? ClusterSupervisionFiles.defaultHealthPath(),
            setup: setup,
            coordinatorURL: coordinatorURL ?? config.coordinator.url,
            autoUpdate: config.provider.autoUpdate && environment["DARKBLOOM_NO_UPDATE_CHECK"] == nil,
            budgetLimits: .resolve(environment),
            guardLimits: .resolve(environment),
            reexecArguments: [executable] + Array(CommandLine.arguments.dropFirst())))
        let signals = try DistributedStartSignals()
        defer { signals.close() }
        signals.attach { supervisor.requestStop() }
        let code = await supervisor.run()
        if code != 0 { throw ExitCode(code) }
    }

    /// The running binary's real path (a symlinked `~/.darkbloom/bin/darkbloom`
    /// resolves into the signed app, whose identity macOS permissions follow).
    static func currentExecutablePath() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = UInt32(MAXPATHLEN)
        if _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return CommandLine.arguments[0]
    }
}

/// The member side of the supervisor's liveness guard: heartbeats written
/// while the member runs. Before the provider loop exists (setup checks,
/// weight hashing) a plain ticker proves the process alive; afterwards every
/// beat is taken on the loop actor, so a wedged loop stops beating.
final class ClusterMemberHeartbeat: @unchecked Sendable {
    private let path: URL?
    private let lock = NSLock()
    private var registeredAt: Double?
    private var servingSince: Double?
    private var task: Task<Void, Never>?
    static let intervalNanoseconds: UInt64 = 5_000_000_000

    /// Whether a supervisor asked for heartbeats (it set the health file path).
    var isSupervised: Bool { path != nil }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        path = environment[ClusterSupervisionFiles.healthPathEnvironmentKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// Beats `.starting` until `attach(loop:)`.
    func startEarly() {
        guard path != nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.write(.init(phase: .starting, engineWedgedSeconds: nil, warmup: nil))
                try? await Task.sleep(nanoseconds: Self.intervalNanoseconds)
            }
        }
    }

    /// From now on each beat is taken on the loop actor (which also refreshes
    /// the daemon state the launchd watchdog reads, supervised or not).
    func attach(loop: ProviderLoop) {
        task?.cancel()
        // Runs unsupervised too: the beat refreshes the daemon state.
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let sample = await loop.clusterMemberHeartbeat()
                self?.write(sample)
                try? await Task.sleep(nanoseconds: Self.intervalNanoseconds)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        write(.init(phase: .stopping, engineWedgedSeconds: nil, warmup: nil))
    }

    private func write(_ sample: ClusterMemberHeartbeatSample) {
        guard let path else { return }
        let now = Date().timeIntervalSince1970
        let phase = sample.phase
        let (registered, serving): (Double?, Double?) = lock.withLock {
            if phase == .registered || phase == .serving, registeredAt == nil { registeredAt = now }
            if phase == .serving { servingSince = servingSince ?? now } else if phase != .stopping { servingSince = nil }
            return (registeredAt, servingSince)
        }
        ClusterSupervisionFiles.write(ClusterMemberHealth(pid: getpid(), version: ProviderCore.version, phase: phase,
            writtenAt: now, registeredAt: registered, servingSince: serving,
            engineWedgedSeconds: sample.engineWedgedSeconds, warmup: sample.warmup, busy: sample.busy), to: path)
    }
}
