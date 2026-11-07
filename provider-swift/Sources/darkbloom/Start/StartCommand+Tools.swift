import ArgumentParser
import Foundation
import ProviderCore

// `darkbloom start --opencode` / `--hermes`: start Darkbloom only if no local API runs, then point the tools at it
// (ToolIntegrationStep). They run once, at start: never in the launchd child, never per request.
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
    func runningLocalAPI(_ live: LocalEndpoint.Info?, keyFile: (UInt16) -> URL?,
                         ignoringWhatServes: Bool = false) -> IntegrationEndpoint? {
        guard !requestedTools.isEmpty, ignoringWhatServes || !changesWhatServes, let live, !live.apiKey.isEmpty,
              portOption.map({ $0 == live.port }) ?? true, bindOption.map({ $0 == live.host }) ?? true,
              let file = keyFile(live.port) else { return nil }
        return IntegrationEndpoint(baseURL: live.baseURL, keyFile: file)
    }

    /// `--coordinator-url`, else the config's, else the build's: where the catalog's model names come from. Reads the
    /// config without detecting hardware.
    func configuredCoordinatorURL() -> String {
        if let coordinatorURL { return coordinatorURL }
        let path = configOptions.config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? (try? ConfigManager.defaultConfigPath())
        return path.flatMap { try? ConfigManager.load(from: $0) }?.coordinator.url
            ?? BuildEnvironment.current.coordinatorWebSocketURL
    }

    /// Runs the tools' step beside a pair that just started: for its local API on this Mac, when there is one.
    func setUpToolsBesidePair() async throws {
        guard !requestedTools.isEmpty else { return }
        guard let endpoint = runningLocalAPI(LocalEndpoint.readLiveInfo(),
                                             keyFile: { LocalEndpoint.keyFile(forPort: Int($0)) },
                                             ignoringWhatServes: true) else {
            print(ToolIntegrationStep.noPairAPI(requestedTools))
            print("Darkbloom keeps serving.")
            throw ExitCode.failure
        }
        let saved: LocalSettings? = (try? savedLocalSettings(configPath: configOptions.config)) ?? nil
        guard await setUpTools(endpoint: endpoint, route: saved?.route, accountKeySaved: nil,
                               coordinatorURL: configuredCoordinatorURL()) else { throw ExitCode.failure }
    }

    /// Sets the requested tools up for `endpoint`; false when one couldn't be.
    func setUpTools(endpoint: IntegrationEndpoint, route: LocalSettings.Route?, accountKeySaved: Bool?,
                    coordinatorURL: String) async -> Bool {
        let keySaved = accountKeySaved ?? Start.accountKeySaved()
        return await ToolIntegrationStep.live(tools: requestedTools, coordinatorURL: coordinatorURL)
            .run(endpoint: endpoint, requests: LocalFirstWords.requests(route: route, accountKeySaved: keySaved))
    }

    /// Waits for the background provider's local API on `port`: it writes `local.json` once bound. Bounded, and only
    /// at start.
    static func waitForLocalAPI(port: UInt16, seconds: Int,
                                live: () -> LocalEndpoint.Info? = { LocalEndpoint.readLiveInfo() },
                                keyFile: (UInt16) -> URL? = { LocalEndpoint.keyFile(forPort: Int($0)) },
                                pause: () async -> Void = { try? await Task.sleep(nanoseconds: 250_000_000) })
        async -> IntegrationEndpoint? {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        repeat {
            if let info = live(), info.port == port, !info.apiKey.isEmpty, let file = keyFile(info.port) {
                return IntegrationEndpoint(baseURL: info.baseURL, keyFile: file)
            }
            await pause()
        } while Date() < deadline
        return nil
    }
}
