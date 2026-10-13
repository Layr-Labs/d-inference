import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// This Mac's cluster service (`darkbloom cluster` installs it as a login
    /// agent once the Mac is paired): answers the leader over the link control
    /// channel, applies the setup a member's leader syncs, and runs this Mac's
    /// part while the leader has the cluster serving. Runs until SIGTERM or SIGINT.
    ///
    /// launchd runs it as `--supervise`: the S18 supervisor, which runs the
    /// service as its child and restarts it with the restart budget and backoff.
    struct Service: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "service",
            abstract: "Run this Mac's cluster service (started by `darkbloom cluster`).", shouldDisplay: false)
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Absolute path of this Mac's cluster worker, when it is not the installed one (Darkbloom.app/Contents/Helpers).")
        var worker: String?
        @Flag(help: "Run the supervisor that keeps the service running (what the login agent runs).")
        var supervise = false
        @Flag(help: "Install the service as this Mac's login agent (what `darkbloom cluster` does) and exit.")
        var install = false

        func validate() throws {
            for path in [configOptions.config, worker].compactMap({ $0 }) where !path.hasPrefix("/") {
                throw ValidationError("The cluster service takes absolute paths.")
            }
            guard !(supervise && install) else { throw ValidationError("Choose at most one of --supervise and --install.") }
        }

        var serviceOptions: [String] { ClusterServiceAgentPlan.serviceOptions(config: configOptions.config, worker: worker) }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            if install { return try installAgent() }
            if supervise { return try await runSupervisor() }
            let settings = try Cluster.Setup.serviceSettings(config: configOptions.config, modelDir: nil, worker: worker)
            let service = try ClusterService(settings: settings)
            let stop = DispatchSemaphore(value: 0)
            let signals = try DistributedStartSignals()
            defer { signals.close() }
            signals.attach { stop.signal() }
            // Under its supervisor: a heartbeat for the liveness guard, and an end
            // of its own when the supervisor is gone (a restarted supervisor
            // starts a new service, which needs this one's lock).
            let supervision = ClusterServiceSupervision(environment: ProcessInfo.processInfo.environment)
            supervision?.start(stop: stop, running: { ClusterService.published()?.child.running ?? false })
            defer { supervision?.finish() }
            let clean = try await Task.detached {
                try service.run(stop: stop) { text in
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    FileHandle.standardOutput.write(Data("\(stamp) cluster service: \(text)\n".utf8))
                }
            }.value
            if !clean { throw ExitCode(3) }
        }

        private func installAgent() throws {
            let executable = URL(fileURLWithPath: Start.currentExecutablePath())
            let outcome = try ClusterService.installAtLogin(executable: executable, serviceOptions: serviceOptions)
            let job = try ClusterService.loginAgentJob(executable: executable, serviceOptions: serviceOptions)
            print("Cluster service login agent \(job.label): \(outcome.rawValue); it starts at login and its supervisor restarts it with backoff.")
        }

        /// `cluster service --supervise`: the S18 supervisor around `cluster service`.
        private func runSupervisor() async throws {
            let environment = ProcessInfo.processInfo.environment
            let directory = try ClusterService.paths().lock.deletingLastPathComponent()
            let executable = Start.currentExecutablePath()
            let supervisor = ClusterMemberSupervisor(configuration: .init(
                executable: executable,
                childArguments: ClusterServiceAgentPlan.childArguments(serviceOptions: serviceOptions),
                environment: environment,
                statePath: ClusterServiceAgent.supervisorStatePath(serviceDirectory: directory),
                healthPath: ClusterServiceAgent.healthPath(serviceDirectory: directory),
                // The service waits for the cable itself (it answers once the link is up) and is
                // updated with the app, not at the member's update slot.
                setup: nil, coordinatorURL: "", autoUpdate: false,
                budgetLimits: .resolve(environment), guardLimits: .resolve(environment),
                recycleGraceSeconds: Double(ClusterServiceAgentPlan.partStopGraceSeconds),
                reexecArguments: [executable] + Array(CommandLine.arguments.dropFirst()),
                logName: "cluster service supervisor",
                restartHint: "`darkbloom cluster` is run again (or `darkbloom cluster stop`)"))
            let signals = try DistributedStartSignals()
            defer { signals.close() }
            signals.attach { supervisor.requestStop() }
            // Exit 0 also when another supervisor already keeps the service, so launchd does not relaunch this one.
            _ = await supervisor.run()
        }
    }

    /// `darkbloom cluster stop`: stops this Mac's cluster service and keeps it
    /// stopped across restarts of this Mac (its login agent is removed). On the
    /// leader the cluster stops serving first (the members stop their parts).
    /// `darkbloom cluster` starts it again.
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop",
            abstract: "Stop this Mac's cluster service and keep it from starting at login (`darkbloom cluster` starts it again).")
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Absolute path of this Mac's cluster worker, when it is not installed beside darkbloom.")
        var worker: String?

        func validate() throws {
            for path in [configOptions.config, worker].compactMap({ $0 }) where !path.hasPrefix("/") {
                throw ValidationError("darkbloom cluster stop takes absolute paths.")
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let config = configOptions.config, worker = worker
            let executable = URL(fileURLWithPath: Start.currentExecutablePath())
            let lines: [String] = try await Task.detached {
                var lines: [String] = []
                // The leader stops serving first, so its members stop their parts too.
                if let settings = try? Cluster.Setup.serviceSettings(config: config, modelDir: nil, worker: worker),
                   let operations = try? ClusterOnboardingOperations.live(.init(service: settings,
                       serviceArguments: ClusterServiceAgentPlan.childArguments(
                           serviceOptions: ClusterServiceAgentPlan.serviceOptions(config: config, worker: worker)))) {
                    let resume = operations.resume()
                    if resume.role == .leader, resume.serving {
                        switch operations.stop() {
                        case .success(let said): lines += said
                        case .failure(let failure): lines += failure.lines
                        }
                    }
                }
                let removed = try ClusterService.removeFromLogin(executable: executable)
                lines.append(removed.isEmpty
                    ? "This Mac's cluster service is stopped (it was not set to start at login)."
                    : "This Mac's cluster service is stopped and will not start at login. Run `darkbloom cluster` to start it again.")
                return lines
            }.value
            for line in lines { print(line) }
        }
    }
}

/// The supervised service's side of the S18 supervision: a heartbeat the
/// liveness guard reads (the service has no provider loop; a ticker of its
/// own proves the process alive), and an end of its own when its supervisor
/// is gone. Present only when a supervisor started this process.
final class ClusterServiceSupervision: @unchecked Sendable {
    private let healthPath: URL
    private let parent = getppid()
    private let lock = NSLock()
    private var finished = false

    init?(environment: [String: String]) {
        guard let path = environment[ClusterSupervisionFiles.healthPathEnvironmentKey], !path.isEmpty else { return nil }
        healthPath = URL(fileURLWithPath: path)
    }

    func start(stop: DispatchSemaphore, running: @escaping @Sendable () -> Bool) {
        Thread.detachNewThread { [self] in
            var stopped = false
            while !lock.withLock({ finished }) {
                beat(running() ? .serving : .registered)
                if !stopped, getppid() != parent {
                    // The supervisor ended without stopping this service (a crash or SIGKILL): stop
                    // this Mac's part and leave, so the supervisor launchd starts again takes over.
                    stopped = true
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    FileHandle.standardOutput.write(Data("\(stamp) cluster service: its supervisor is gone; stopping\n".utf8))
                    stop.signal()
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    func finish() {
        lock.withLock { finished = true }
        beat(.stopping)
    }

    private func beat(_ phase: ClusterMemberHealth.Phase) {
        ClusterSupervisionFiles.write(ClusterMemberHealth(pid: getpid(), version: ProviderCore.version, phase: phase,
            writtenAt: Date().timeIntervalSince1970), to: healthPath)
    }
}
