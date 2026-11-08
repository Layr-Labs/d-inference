import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// Only me's own server from its construction until it listens (`Start.startOnlyMeServer`), with a stand-in that
/// records each step: building a `StandaloneServer` needs Metal. Nothing here binds a port, writes the daemon state or
/// runs launchctl.
@Suite("Only me's own server: what runs, in which order")
struct OnlyMeServerStartTests {
    /// The steps `runLocalStandalone` takes for `arguments`, with the release confirmation among them;
    /// `launchdJob` says whether launchd's job of Only me's background service runs this process.
    static func steps(_ arguments: [String], launchdJob: Bool, preload: Bool = true, idleMinutes: UInt64 = 60,
                      autoUpdate: Bool = true) async throws -> [String] {
        let file = try TempConfig("[provider]\nname = \"only-me-server\"\n")
        defer { file.remove() }
        var config = ProviderConfig(provider: ProviderSettings(name: "only-me-server"))
        config.backend.startupPreload = preload
        config.backend.idleTimeoutMins = idleMinutes
        config.provider.autoUpdate = autoUpdate
        let serving = StartServing(mode: .local, source: .today, meFirst: false, meFirstIdleMinutes: 2, route: nil,
                                   accountKeySaved: nil, port: 8003, bind: "127.0.0.1", noAuth: false)
        let log = StepLog()
        let serves = try await file.start(arguments).startOnlyMeServer(
            RecordingOnlyMeServer(log: log), config: config, serving: serving, termination: ProviderTermination(),
            stateFile: file.directory.appendingPathComponent("daemon-state.json"), launchdJob: launchdJob,
            confirmRelease: { log.add("confirm \($0)") })
        #expect(serves, "\(arguments)")
        return log.all
    }

    static let coordinator = ProviderConfig(provider: ProviderSettings(name: "only-me-server")).coordinator.url

    /// The steps but the heartbeat and the release confirmation, whose place `heartbeatBeforeThePreload` checks.
    static func besides(_ steps: [String]) -> [String] {
        steps.filter { $0 != "heartbeat" && !$0.hasPrefix("confirm") }
    }

    /// Once Only me's server listens: the idle unload, always; the release confirmation and the update loop only in
    /// launchd's job of Only me's background service, never in `--here`'s terminal or a cluster's solo part (the
    /// cluster service's child). Without them Only me never updates itself, or a terminal session updates and restarts
    /// under its owner.
    @Test("Only me's server unloads idle models; only its background service confirms its release and updates itself")
    func whatRunsBesideIt() async throws {
        let service = try await Self.steps(["--foreground", "--local", "--port", "8003"], launchdJob: true)
        #expect(Self.besides(service) == ["preload", "listen", "bound", "idle unload 60", "updates on"], "\(service)")
        #expect(service.filter { $0.hasPrefix("confirm") } == ["confirm \(Self.coordinator)"])
        for (arguments, which) in [(["--local", "--here"], "--here"),
                                   (["--foreground", "--local", "--port", "8000"], "a cluster's solo part")] {
            let steps = try await Self.steps(arguments, launchdJob: false)
            #expect(Self.besides(steps) == ["preload", "listen", "bound", "idle unload 60"], "\(which): \(steps)")
            #expect(!steps.contains { $0.hasPrefix("confirm") }, "\(which)")
        }
        // The settings as saved: 0 minutes keeps models loaded; `auto_update = false` asks the loop not to run.
        let off = try await Self.steps(["--foreground", "--local"], launchdJob: true, idleMinutes: 0, autoUpdate: false)
        #expect(Self.besides(off).suffix(2) == ["idle unload 0", "updates off"], "\(off)")
    }

    /// Only me's background service after an update can load for longer than the watchdog's 5 minutes: its preload
    /// waits for every model it serves, with no time limit. Its heartbeat (the daemon state, kept fresh, and the
    /// lifecycle mailbox) starts before that, after its release confirmation, as the network provider's do
    /// (`runForeground`, `ProviderLoop.run`), so a long first load is never taken for a failed start, killed, and after
    /// three kills rolled back (`WatchdogRecoveryIntegrationTests.onlyMeLongPreloadAfterAnUpdate`).
    @Test("Only me's heartbeat starts before its preload, which has no time limit, after its release confirmation")
    func heartbeatBeforeThePreload() async throws {
        let service = try await Self.steps(["--foreground", "--local", "--port", "8003"], launchdJob: true)
        #expect(Array(service.prefix(3)) == ["confirm \(Self.coordinator)", "heartbeat", "preload"], "\(service)")
        let here = try await Self.steps(["--local", "--here"], launchdJob: false)
        #expect(Array(here.prefix(2)) == ["heartbeat", "preload"], "\(here)")
        // Without a startup preload, before the listener.
        let lazy = try await Self.steps(["--foreground", "--local"], launchdJob: true, preload: false)
        #expect(Array(lazy.prefix(3)) == ["confirm \(Self.coordinator)", "heartbeat", "listen"], "\(lazy)")
    }
}

/// Steps in the order they happened, from any task.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    func add(_ step: String) {
        lock.lock()
        steps.append(step)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
}

/// Only me's server as `Start.startOnlyMeServer` drives it: each step goes to `log`, and it binds at once.
actor RecordingOnlyMeServer: OnlyMeServer {
    let log: StepLog

    init(log: StepLog) { self.log = log }

    func startLifecycleControl(stateFile: URL) { log.add("heartbeat") }

    func preloadSelectedModels(configuredModelIDs: [String]) async -> StartupPreloader.Summary {
        log.add("preload")
        return StartupPreloader.Summary()
    }

    func start() throws { log.add("listen") }

    func waitUntilBound(timeoutSeconds: Double) async -> Bool {
        log.add("bound")
        return true
    }

    func stop() async { log.add("stop") }

    func drainAndStop(timeoutSeconds: Int) async -> Bool {
        log.add("drain")
        return true
    }

    func startIdleUnload(minutes: UInt64, every interval: Duration) { log.add("idle unload \(minutes)") }

    func startAutoUpdateMonitor(coordinatorURL: String, enabled: Bool, environment: [String: String]) {
        log.add("updates \(enabled ? "on" : "off")")
    }
}
