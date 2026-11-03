import ArgumentParser
import Foundation
import Testing
@testable import darkbloom
@testable import ProviderCore

/// `darkbloom update --rollback` against a temporary install root. The host
/// (cluster check, launchd, drain, restart, prompt) is injected, so no real
/// install, launchd job or provider process is touched.
@Suite("Update rollback command", .serialized)
struct UpdateRollbackCommandTests {
    @Test("update parses --rollback with --yes and the drain options, and refuses mixed flags")
    func parsing() throws {
        let update = try #require(try Darkbloom.parseAsRoot(["update", "--rollback", "--yes", "--timeout", "30"]) as? Update)
        #expect(update.rollback)
        #expect(update.yes)
        #expect(update.drain.timeout == 30)
        for arguments in [
            ["update", "--rollback", "--check-only"],
            ["update", "--rollback", "--override-quarantine"],
            ["update", "--rollback", "--coordinator", "https://override.invalid"],
            ["update", "--yes"],
        ] {
            #expect(throws: (any Error).self, "\(arguments)") { try Darkbloom.parseAsRoot(arguments) }
        }
    }

    @Test("a confirmed rollback drains, swaps, restarts and quarantines")
    func confirmedRollbackOfARunningProvider() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        let host = RecordingHost(install: install, loaded: true, answer: "y")

        try await install.rollback(host: host, yes: false)

        #expect(host.events == ["drain", "restart", "wait"])
        #expect(try install.liveBinary() == "1.0.0-darkbloom")
        let state = try install.store.loadState()
        #expect(state.current?.version == "1.0.0")
        #expect(state.quarantine?.version == "2.0.0")
        #expect(host.said.contains("Roll back this Mac:"))
        #expect(host.said.contains("  v2.0.0 (installed) -> v1.0.0 (the release kept for rollback, install generation 0)"))
        #expect(host.said.contains("Roll back to v1.0.0? [y/N]"))
        #expect(host.said.contains("Rolled back: v2.0.0 -> v1.0.0."))
    }

    @Test("--yes skips the prompt, and a stopped provider is swapped without a drain or restart")
    func yesWithAStoppedProvider() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        let host = RecordingHost(install: install, loaded: false, canAsk: false)

        try await install.rollback(host: host, yes: true)

        #expect(host.events.isEmpty)
        #expect(try install.liveBinary() == "1.0.0-darkbloom")
        #expect(!host.said.contains { $0.contains("[y/N]") })
        #expect(host.said.contains("The provider is not running; `darkbloom start` starts v1.0.0."))
    }

    @Test("a declined or unanswerable prompt changes nothing")
    func declinedPrompt() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        let declining = RecordingHost(install: install, loaded: true, answer: "")
        try await install.rollback(host: declining, yes: false)
        #expect(declining.said.last == "Nothing changed.")

        let noTerminal = RecordingHost(install: install, loaded: true, canAsk: false)
        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: noTerminal, yes: false) }
        #expect(error?.description.contains("--yes") == true)

        #expect(declining.events.isEmpty && noTerminal.events.isEmpty)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        #expect(try install.store.loadState().quarantine == nil)
    }

    @Test("a cluster Mac, a foreground provider, a held lease and a missing predecessor are refused before any drain")
    func refusals() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }

        let cluster = RecordingHost(install: install, loaded: true, inCluster: true)
        let clusterError = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: cluster, yes: true) }
        #expect(clusterError?.description.contains("darkbloom cluster stop") == true)

        let foreground = RecordingHost(install: install, loaded: false, foreground: true)
        let foregroundError = await #expect(throws: UpdateRollback.Failure.self) {
            try await install.rollback(host: foreground, yes: true)
        }
        #expect(foregroundError?.description.contains("start --foreground") == true)

        let holder = try install.updater.beginUpdateSession(operation: "watchdog-recovery")
        let busy = RecordingHost(install: install, loaded: true)
        let busyError = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: busy, yes: true) }
        #expect(busyError?.description.contains("watchdog-recovery") == true)
        holder.release()

        let fresh = try RollbackInstall(updated: false)
        defer { fresh.remove() }
        let none = RecordingHost(install: fresh, loaded: true)
        let noneError = await #expect(throws: UpdateRollback.Failure.self) { try await fresh.rollback(host: none, yes: true) }
        #expect(noneError?.description.contains("no earlier release") == true)

        #expect(cluster.events.isEmpty && foreground.events.isEmpty && busy.events.isEmpty && none.events.isEmpty)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        #expect(try fresh.liveBinary() == "1.0.0-darkbloom")
    }

    @Test("a rollback that fails after the drain still restarts the provider on a complete release")
    func failureAfterDrainRestarts() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        // The predecessor changes between confirmation and the swap.
        let host = RecordingHost(install: install, loaded: true, answer: "yes", beforeDrain: {
            try Data("tampered".utf8).write(to: install.root.appendingPathComponent(
                "recovery/predecessor/Darkbloom.app/Contents/MacOS/darkbloom"))
        })

        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: host, yes: false) }

        #expect(error?.description.contains("Rollback did not complete") == true)
        #expect(error?.description.contains("restarted on the installed release") == true)
        #expect(error?.description.contains("..") == false)
        #expect(host.events == ["drain", "restart"])
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        #expect(try install.store.loadState().quarantine == nil)
        // The lease is free again for the watchdog and the restarted provider.
        try install.updater.beginUpdateSession(operation: "lease-check").release()
    }

    @Test("a provider started during the prompt is not swapped under, and one stopped during it is not restarted")
    func providerChangesDuringThePrompt() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        let started = RecordingHost(install: install, loaded: false, answer: "y", providerOnceAnswered: .service)
        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: started, yes: false) }
        #expect(error?.description == UpdateRollback.startedRefusal)
        #expect(started.events.isEmpty)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        #expect(try install.store.loadState().quarantine == nil)

        // Read under the lease before any drain: a provider that stopped is not drained either.
        let stopped = RecordingHost(install: install, loaded: true, answer: "y", providerOnceAnswered: .stopped)
        try await install.rollback(host: stopped, yes: false)
        #expect(stopped.events.isEmpty)
        #expect(try install.liveBinary() == "1.0.0-darkbloom")
        #expect(try install.store.loadState().quarantine?.version == "2.0.0")
        #expect(stopped.said.last == "The provider is not running; `darkbloom start` starts v1.0.0.")
    }

    // R4-1729-A: the cluster check and the provider check ran before the
    // prompt only. Both are decided again under the update lease, before the
    // drain, and nothing is changed when either changed during the prompt.

    @Test("a Mac that joins a cluster pair during the prompt is refused under the lease, with nothing changed",
          arguments: [true, false])
    func clusterMembershipChangesDuringThePrompt(loaded: Bool) async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        let host = RecordingHost(install: install, loaded: loaded, answer: "y", inClusterOnceAnswered: true)

        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: host, yes: false) }

        #expect(error?.description == UpdateRollback.clusterRefusal)
        #expect(host.events.isEmpty)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        let state = try install.store.loadState()
        #expect(state.current?.version == "2.0.0")
        #expect(state.quarantine == nil)
        try install.updater.beginUpdateSession(operation: "lease-check").release()
    }

    @Test("a service provider replaced by a foreground provider during the prompt is refused before any drain")
    func serviceReplacedByForegroundDuringThePrompt() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        let host = RecordingHost(install: install, loaded: true, answer: "y", providerOnceAnswered: .foreground)

        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: host, yes: false) }

        #expect(error?.description == UpdateRollback.foregroundRefusal)
        #expect(host.events.isEmpty)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        #expect(try install.store.loadState().quarantine == nil)
        try install.updater.beginUpdateSession(operation: "lease-check").release()
    }

    @Test("the rollback and a pair's coordinated update exclude each other through the update lease")
    func sharedExclusionWithThePairUpdate() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }

        // A pair update cycle holds the lease (`ClusterPairUpdateCycle.claim`): the rollback is refused.
        let cycle = try install.updater.beginUpdateSession(operation: "cluster-auto-update")
        let refused = RecordingHost(install: install, loaded: true, answer: "y")
        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: refused, yes: true) }
        #expect(error?.description.contains("cluster-auto-update") == true)
        #expect(refused.events.isEmpty)
        cycle.release()

        // The rollback holds the lease from the drain to the swap: a pair update cycle cannot claim it, and no
        // cluster service can start.
        let probe = Probe()
        let host = RecordingHost(install: install, loaded: true, answer: "y", beforeDrain: {
            probe.cycleRefused = (try? install.updater.beginUpdateSession(operation: "cluster-auto-update")) == nil
            probe.serviceHeldOut = try !install.isFree(install.clusterServiceLock)
        })
        try await install.rollback(host: host, yes: true)
        #expect(probe.cycleRefused && probe.serviceHeldOut)
        #expect(try install.liveBinary() == "1.0.0-darkbloom")
        #expect(try install.isFree(install.clusterServiceLock))
        try install.updater.beginUpdateSession(operation: "lease-check").release()
    }

    @Test("a stopped provider is held out of starting over the swap, and a provider holding its lock refuses the rollback")
    func stoppedProviderStartsAreHeldOut() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }

        let racing = RecordingHost(install: install, loaded: false, providerHoldsInstanceLock: true)
        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: racing, yes: true) }
        #expect(error?.description == UpdateRollback.startedRefusal)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
        #expect(try install.store.loadState().quarantine == nil)

        let stopped = RecordingHost(install: install, loaded: false)
        try await install.rollback(host: stopped, yes: true)
        #expect(try install.liveBinary() == "1.0.0-darkbloom")
        #expect(try install.isFree(install.providerInstanceLock))
        #expect(try install.isFree(install.clusterServiceLock))
    }

    @Test("a hold that cannot be taken refuses with nothing changed")
    func unopenableHoldRefuses() async throws {
        let install = try RollbackInstall()
        defer { install.remove() }
        // A directory where the lock file belongs cannot be opened as a lock.
        try FileManager.default.createDirectory(at: install.clusterServiceLock, withIntermediateDirectories: true)
        let host = RecordingHost(install: install, loaded: true, answer: "y")

        let error = await #expect(throws: UpdateRollback.Failure.self) { try await install.rollback(host: host, yes: true) }

        #expect(error?.description.contains("could not lock out a concurrent start") == true)
        #expect(host.events.isEmpty)
        #expect(try install.liveBinary() == "2.0.0-darkbloom")
    }
}

/// v1 installed, then v2 installed and promoted by the updater, in a temporary root.
private struct RollbackInstall {
    let root: URL
    let scratch: URL

    init(updated: Bool = true) throws {
        let fm = FileManager.default
        scratch = fm.temporaryDirectory.appendingPathComponent("update-rollback-cli-\(UUID().uuidString)")
        root = scratch.appendingPathComponent("install")
        try Self.writeApp(version: "1.0.0", in: root)
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.createSymbolicLink(
                atPath: bin.appendingPathComponent(name).path,
                withDestinationPath: "../Darkbloom.app/Contents/MacOS/\(name)")
        }
        guard updated else { return }

        let source = scratch.appendingPathComponent("release")
        try Self.writeApp(version: "2.0.0", in: source)
        let flat = source.appendingPathComponent("bin")
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.copyItem(
                at: source.appendingPathComponent("Darkbloom.app/Contents/MacOS/\(name)"),
                to: flat.appendingPathComponent(name))
        }
        let tarball = scratch.appendingPathComponent("release.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", tarball.path, "-C", source.path, "."]
        try tar.run()
        tar.waitUntilExit()
        let release = ReleaseInfo(version: "2.0.0", platform: "macos-arm64", url: "unused://", bundleHash: "unused")
        let installer = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:9", installRoot: root, verifyCodeSignatures: false,
            currentVersion: "1.0.0")
        guard case .success = installer.installBundleForTesting(from: tarball, release: release, installDir: root) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var state = try store.loadState()
        state.promoteCandidate()
        try store.writeState(state)
    }

    var updater: SelfUpdater {
        SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:9", installRoot: root, verifyCodeSignatures: false,
            currentVersion: "2.0.0")
    }

    var store: UpdateRecoveryStore { UpdateRecoveryStore(installRoot: root, verifyCodeSignatures: false) }

    /// Stand-ins for the cluster service lock and the provider instance lock, which the rollback holds over its swap.
    var clusterServiceLock: URL { scratch.appendingPathComponent("cluster-setup/service.lock") }
    var providerInstanceLock: URL { scratch.appendingPathComponent("provider.pid.lock") }

    /// Whether `lock` is free now (taken and released at once).
    func isFree(_ lock: URL) throws -> Bool {
        guard let held = try UpdateProcessLock.acquireUnlessBusy(at: lock, operation: "lock-check") else { return false }
        held.release()
        return true
    }

    func rollback(host: RecordingHost, yes: Bool) async throws {
        try await UpdateRollback(updater: updater, host: host.host, say: host.say).run(skipConfirmation: yes)
    }

    func liveBinary() throws -> String {
        try String(contentsOf: root.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom"), encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: scratch) }

    private static func writeApp(version: String, in root: URL) throws {
        let macOS = root.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        for (name, suffix) in [("darkbloom", "darkbloom"), ("darkbloom-enclave", "enclave"), ("mlx.metallib", "metallib")] {
            try Data("\(version)-\(suffix)".utf8).write(to: macOS.appendingPathComponent(name))
        }
    }
}

/// The injected host: records drains, restarts and printed lines.
private final class RecordingHost: @unchecked Sendable {
    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        var lines: [String] = []
        var provider: UpdateRollback.Provider = .stopped
        var inCluster = false
        var providerHoldsInstanceLock = false
    }

    private let log: Log
    let host: UpdateRollback.Host
    var events: [String] { log.lock.withLock { log.events } }
    var said: [String] { log.lock.withLock { log.lines } }

    /// `providerOnceAnswered` is the provider's state from the prompt's answer on.
    /// `inClusterOnceAnswered`: this Mac joins a cluster pair while the prompt is open.
    /// `providerHoldsInstanceLock`: a provider holds its instance lock without showing in the state file yet.
    init(install: RollbackInstall, loaded: Bool, foreground: Bool = false, inCluster: Bool = false, canAsk: Bool = true,
         answer: String? = nil, providerOnceAnswered: UpdateRollback.Provider? = nil,
         inClusterOnceAnswered: Bool? = nil, providerHoldsInstanceLock: Bool = false,
         beforeDrain: @escaping () throws -> Void = {}) {
        let log = Log()
        log.provider = loaded ? .service : foreground ? .foreground : .stopped
        log.inCluster = inCluster
        log.providerHoldsInstanceLock = providerHoldsInstanceLock
        self.log = log
        let record = { (event: String) in log.lock.withLock { log.events.append(event) } }
        host = UpdateRollback.Host(
            servesInCluster: { log.lock.withLock { log.inCluster } },
            holdClusterOut: {
                guard !log.lock.withLock({ log.inCluster }) else { return nil }
                return try UpdateProcessLock.acquireUnlessBusy(at: install.clusterServiceLock, operation: UpdateRollback.operation)
            },
            provider: { log.lock.withLock { log.provider } },
            holdProviderStartsOut: {
                guard !log.lock.withLock({ log.providerHoldsInstanceLock }) else { return nil }
                return try UpdateProcessLock.acquireUnlessBusy(at: install.providerInstanceLock, operation: UpdateRollback.operation)
            },
            canAsk: { canAsk },
            readAnswer: {
                if let providerOnceAnswered { log.lock.withLock { log.provider = providerOnceAnswered } }
                if let inClusterOnceAnswered { log.lock.withLock { log.inCluster = inClusterOnceAnswered } }
                return answer
            },
            drain: {
                record("drain")
                try beforeDrain()
            },
            restart: { record("restart") },
            waitForRestart: { record("wait") })
    }

    func say(_ line: String) { log.lock.withLock { log.lines.append(line) } }
}

/// What a hook observed while the rollback held its locks.
private final class Probe: @unchecked Sendable {
    var cycleRefused = false
    var serviceHeldOut = false
}
