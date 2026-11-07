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
        return nil
    }

    /// Options that change what serves: with any of them, a running local API isn't enough, and the start runs.
    var changesWhatServes: Bool {
        !model.isEmpty || all || idleTimeout != nil || schedule || autopilot != nil || coordinatorURL != nil
            || choose || meFirst == false || meFirstIdle != nil || route != nil
    }

    /// The running local API the tools can use as it is, so nothing starts: it answers on the `--port` and `--bind`
    /// given, if any, and no option changes what serves. Nil when the start must run.
    func runningLocalAPI(_ live: LocalEndpoint.Info?, keyFile: (UInt16) -> URL?) -> IntegrationEndpoint? {
        guard !requestedTools.isEmpty, !changesWhatServes, let live,
              portOption.map({ $0 == live.port }) ?? true, bindOption.map({ $0 == live.host }) ?? true
        else { return nil }
        return IntegrationEndpoint.live(live, keyFile: keyFile)
    }

    /// Sets the tools up for a local API that already serves as this start would, and says so; false when there is
    /// none, and the start runs.
    func setUpToolsForRunningLocalAPI() async throws -> Bool {
        guard !requestedTools.isEmpty, let live = LocalEndpoint.readLiveInfo(),
              let endpoint = runningLocalAPI(live, keyFile: { LocalEndpoint.keyFile(forPort: Int($0)) })
        else { return false }
        print("Darkbloom already serves on \(live.host):\(live.port); setting up "
            + "\(ToolIntegrationStep.names(requestedTools)) for it.")
        try await setUpToolsWithSavedSettings(endpoint)
        return true
    }

    /// Beside a pair that just started: for its local API on this Mac, when there is one. A pair starts only without
    /// single-Mac options, so no option here changes what serves.
    func setUpToolsBesidePair() async throws {
        guard !requestedTools.isEmpty else { return }
        guard let endpoint = IntegrationEndpoint.live() else {
            print(ToolIntegrationStep.noPairAPI(requestedTools))
            print(ToolIntegrationStep.keepsServing)
            throw ExitCode.failure
        }
        try await setUpToolsWithSavedSettings(endpoint)
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
    /// `toolWaitSeconds`.
    func setUpToolsBesideDaemon(serving: StartServing, coordinatorURL: String) async throws {
        guard !requestedTools.isEmpty else { return }
        guard let endpoint = await Self.waitForLocalAPI(port: serving.port, seconds: Self.toolWaitSeconds) else {
            print(ToolIntegrationStep.notUp(requestedTools, seconds: Self.toolWaitSeconds))
            print(ToolIntegrationStep.keepsServing)
            throw ExitCode.failure
        }
        print()
        guard await setUpTools(endpoint: endpoint, route: serving.route, accountKeySaved: serving.accountKeySaved,
                               coordinatorURL: coordinatorURL) else { throw ExitCode.failure }
    }

    /// For a local API this start didn't resolve (one already running, or the pair's): where your requests go comes
    /// from the saved `[local] route`, and the catalog from `--coordinator-url`, else the config's, else the build's.
    /// Reads the config once, without detecting hardware.
    private func setUpToolsWithSavedSettings(_ endpoint: IntegrationEndpoint) async throws {
        let saved = try? savedConfig(configPath: configOptions.config)
        let coordinator = coordinatorURL ?? saved?.coordinator.url ?? BuildEnvironment.current.coordinatorWebSocketURL
        guard await setUpTools(endpoint: endpoint, route: saved?.local?.route, accountKeySaved: nil,
                               coordinatorURL: coordinator) else { throw ExitCode.failure }
    }

    /// Sets the requested tools up for `endpoint`; false when one couldn't be. `accountKeySaved` nil asks the
    /// Keychain (never printed).
    func setUpTools(endpoint: IntegrationEndpoint, route: LocalSettings.Route?, accountKeySaved: Bool?,
                    coordinatorURL: String) async -> Bool {
        let keySaved = accountKeySaved ?? Start.accountKeySaved()
        return await ToolIntegrationStep.live(tools: requestedTools, coordinatorURL: coordinatorURL)
            .run(endpoint: endpoint, requests: LocalFirstWords.requests(route: route, accountKeySaved: keySaved))
    }

    /// How long a background start waits for its local API before setting tools up.
    static let toolWaitSeconds = 30

    /// Waits for the background provider's local API on `port`: it writes `local.json` once bound. Bounded, and only
    /// at start.
    static func waitForLocalAPI(port: UInt16, seconds: Int,
                                live: () -> LocalEndpoint.Info? = { LocalEndpoint.readLiveInfo() },
                                keyFile: (UInt16) -> URL? = { LocalEndpoint.keyFile(forPort: Int($0)) },
                                pause: () async -> Void = { try? await Task.sleep(nanoseconds: 250_000_000) })
        async -> IntegrationEndpoint? {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        repeat {
            if let info = live(), info.port == port, let endpoint = IntegrationEndpoint.live(info, keyFile: keyFile) {
                return endpoint
            }
            await pause()
        } while Date() < deadline
        return nil
    }
}
