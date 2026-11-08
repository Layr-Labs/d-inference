import ArgumentParser
import Foundation
import ProviderCore

// `darkbloom start --opencode` / `--hermes`: start Darkbloom only if no local API runs, then point the tools at it
// (ToolIntegrationStep). They run once, at start: never in the launchd child, never per request. A start without a
// tool flag reads nothing here. No line, and no tool file, holds a key.
extension Start {
    /// Why `--opencode` / `--hermes` can't go with these flags; nil when they can.
    var toolFlagsRefusal: String? {
        guard let first = requestedTools.first else { return nil }
        if network {
            return "`\(first.flag)` needs this Mac's local API, which `--network` doesn't serve. Use --me-first or "
                + "--local instead."
        }
        if noAuth {
            return "`\(first.flag)` points \(first.displayName) at a local API that needs its key; with `--no-auth` "
                + "anything on this Mac could use it. Drop --no-auth."
        }
        if clusterMember || supervise || alwaysOn {
            return "`\(first.flag)` sets a tool up beside a local API; a --cluster-member start serves none."
        }
        if foreground {
            return "`\(first.flag)` runs once, at `\(BuildEnvironment.current.cliName) start`; the --foreground "
                + "service never sets tools up."
        }
        if distributed {
            return "`\(first.flag)` doesn't start a cluster. Start it first, then run "
                + "`\(BuildEnvironment.current.cliName) start \(first.flag)` on its own: it sets "
                + "\(first.displayName) up for the cluster's local API."
        }
        return nil
    }

    /// Options that change what serves: with any of them, a running local API isn't enough, and the start runs.
    var changesWhatServes: Bool {
        !model.isEmpty || all || idleTimeout != nil || schedule || autopilot != nil || coordinatorURL != nil
            || choose || meFirst == false || meFirstIdle != nil || route != nil
    }

    /// Whether a running local API serves as this start would: it answers on the `--port` and `--bind` given, if
    /// any, and no option changes what serves.
    func servesAsAsked(_ live: LocalEndpoint.Info) -> Bool {
        !changesWhatServes && portOption.map({ $0 == live.port }) ?? true && bindOption.map({ $0 == live.host }) ?? true
    }

    /// The running local API the tools can use as it is, so nothing starts; nil when the start must run.
    func runningLocalAPI(_ live: LocalEndpoint.Info?, keyFile: (UInt16) -> URL?) -> IntegrationEndpoint? {
        guard !requestedTools.isEmpty, let live, servesAsAsked(live) else { return nil }
        return IntegrationEndpoint.live(live, keyFile: keyFile)
    }

    /// Sets the tools up for a local API that already serves as this start would, and says so; false when there is
    /// none, and the start runs. One without a key (`--no-auth`) is named, and nothing starts: tools need its key.
    func setUpToolsForRunningLocalAPI(live: LocalEndpoint.Info? = LocalEndpoint.readLiveInfo(),
                                      step: ToolIntegrationStep? = nil) async throws -> Bool {
        guard !requestedTools.isEmpty, let live, servesAsAsked(live) else { return false }
        guard !live.apiKey.isEmpty else {
            print(ToolIntegrationStep.keyless(port: live.port))
            throw ExitCode.failure
        }
        guard let endpoint = runningLocalAPI(live, keyFile: { LocalEndpoint.keyFile(forPort: Int($0)) }) else {
            return false
        }
        print("Darkbloom already serves on \(live.host):\(live.port); setting up "
            + "\(ToolIntegrationStep.names(requestedTools)) for it.")
        try await setUpToolsWithSavedSettings(endpoint, step: step)
        return true
    }

    /// Beside a pair that just started: for its local API on this Mac, when there is one. A pair starts only without
    /// single-Mac options, or with the app's Start's (`Start.appStartOptions`), which don't change what the pair serves.
    func setUpToolsBesidePair() async throws {
        guard !requestedTools.isEmpty else { return }
        guard let endpoint = IntegrationEndpoint.live() else {
            print(ToolIntegrationStep.noPairAPI(requestedTools))
            print(ToolIntegrationStep.keepsServing)
            throw ExitCode.failure
        }
        try await setUpToolsWithSavedSettings(endpoint, step: nil)
    }

    /// Beside the coordinator-less server, once it is bound, on a task of its own: the server keeps serving whatever
    /// happens there.
    func setUpToolsBesideLocalServer(_ info: LocalEndpoint.Info, serving: StartServing, coordinatorURL: String) {
        guard !requestedTools.isEmpty else { return }
        guard let endpoint = IntegrationEndpoint.live(info) else {
            print("✗ \(ToolIntegrationStep.names(requestedTools)) couldn't be set up: no key file holds this server's "
                + "key. \(ToolIntegrationStep.keepsServing)")
            return
        }
        Task { _ = await setUpTools(endpoint: endpoint, route: serving.route, accountKeySaved: serving.accountKeySaved,
                                    coordinatorURL: coordinatorURL) }
    }

    /// After the background provider started: once its local API is bound, which `local.json` says, waiting at most
    /// `waitSeconds` (Only me listens only once its models are loaded, so it waits longer). A step that fails ends the
    /// start with exit 1; the provider keeps serving.
    func setUpToolsBesideDaemon(serving: StartServing, coordinatorURL: String,
                                waitSeconds: Int = Start.toolWaitSeconds,
                                waitForAPI: (_ port: UInt16, _ seconds: Int) async -> LocalAPIWait = {
                                    await Start.waitForLocalAPI(port: $0, seconds: $1)
                                },
                                step: ToolIntegrationStep? = nil) async throws {
        guard !requestedTools.isEmpty else { return }
        let endpoint: IntegrationEndpoint
        switch await waitForAPI(serving.port, waitSeconds) {
        case .ready(let found):
            endpoint = found
        case .noKeyFile:
            print(ToolIntegrationStep.noKeyFile(requestedTools, port: serving.port))
            print(ToolIntegrationStep.keepsServing)
            throw ExitCode.failure
        case .notUp:
            print(ToolIntegrationStep.notUp(requestedTools, seconds: waitSeconds))
            print(ToolIntegrationStep.keepsServing)
            throw ExitCode.failure
        }
        print()
        guard await setUpTools(endpoint: endpoint, route: serving.route, accountKeySaved: serving.accountKeySaved,
                               coordinatorURL: coordinatorURL, step: step) else { throw ExitCode.failure }
    }

    /// For a local API this start didn't resolve (one already running, or the pair's): where your requests go comes
    /// from the saved `[local] route`, and the catalog from `--coordinator-url`, else the config's, else the build's.
    /// Reads the config once, without detecting hardware.
    private func setUpToolsWithSavedSettings(_ endpoint: IntegrationEndpoint, step: ToolIntegrationStep?) async throws {
        let saved = try? savedConfig(configPath: configOptions.config)
        let coordinator = coordinatorURL ?? saved?.coordinator.url ?? BuildEnvironment.current.coordinatorWebSocketURL
        guard await setUpTools(endpoint: endpoint, route: saved?.local?.route, accountKeySaved: nil,
                               coordinatorURL: coordinator, step: step) else { throw ExitCode.failure }
    }

    /// Sets the requested tools up for `endpoint` with `step` (nil: the tools on this Mac, `ToolIntegrationStep.live`);
    /// false when one couldn't be. `accountKeySaved` nil asks the Keychain (never printed).
    func setUpTools(endpoint: IntegrationEndpoint, route: LocalSettings.Route?, accountKeySaved: Bool?,
                    coordinatorURL: String, step: ToolIntegrationStep? = nil) async -> Bool {
        let keySaved = accountKeySaved ?? Start.accountKeySaved()
        return await (step ?? ToolIntegrationStep.live(tools: requestedTools, coordinatorURL: coordinatorURL))
            .run(endpoint: endpoint, requests: LocalFirstWords.requests(route: route, accountKeySaved: keySaved))
    }

    /// How long a background start waits for its local API before setting tools up.
    static let toolWaitSeconds = 30

    /// What the wait for a background start's local API found.
    enum LocalAPIWait: Equatable, Sendable {
        case ready(IntegrationEndpoint)
        /// `local.json` names the port with a key, but no key file holds it: waiting longer changes nothing.
        case noKeyFile
        case notUp
    }

    /// Waits for the background provider's local API on `port`: it writes `local.json` once bound. Bounded, and only
    /// at start.
    static func waitForLocalAPI(port: UInt16, seconds: Int,
                                live: () -> LocalEndpoint.Info? = { LocalEndpoint.readLiveInfo() },
                                keyFile: (UInt16) -> URL? = { LocalEndpoint.keyFile(forPort: Int($0)) },
                                pause: () async -> Void = { try? await Task.sleep(nanoseconds: 250_000_000) })
        async -> LocalAPIWait {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        repeat {
            if let info = live(), info.port == port {
                if let endpoint = IntegrationEndpoint.live(info, keyFile: keyFile) { return .ready(endpoint) }
                if !info.apiKey.isEmpty { return .noKeyFile }
            }
            await pause()
        } while Date() < deadline
        return .notUp
    }
}
