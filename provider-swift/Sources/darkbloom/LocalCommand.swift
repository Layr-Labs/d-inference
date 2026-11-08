import ArgumentParser
import Foundation
import ProviderCore
import SystemConfiguration

/// `darkbloom local` — print the direct/local-mode endpoint (URL + API key)
/// for the OpenAI-compatible server started by `darkbloom start --local`, with
/// ready-to-paste client examples. `--json` emits the raw discovery record for
/// tooling.
struct Local: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "local",
        abstract: "Show the local (direct-mode) OpenAI endpoint and API key.",
        discussion: """
        Reads ~/\(BuildEnvironment.current.installDirectoryName)/local.json, written by `\(BuildEnvironment.current.cliName) start --local`.
        Point any OpenAI client at the base URL with the API key to run
        inference on this Mac directly — free, and without the coordinator.
        """
    )

    @Flag(help: "Emit the raw discovery record as JSON.")
    var json = false

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        // readLiveInfo() returns nil when the recorded server process is gone,
        // so a stale local.json from a Ctrl-C/crash is treated as "not running"
        // rather than advertising a dead endpoint.
        // On a Mac that relays a pair's API: why it has no working address now, in `status`'s words.
        let pair = ClusterPairSummary.local()
        guard let info = LocalEndpoint.readLiveInfo() else {
            if json {
                print("{}")
            } else if pair.relaying == nil, let down = pair.memberAPIDown {
                printError("Local API: " + down)
            } else if let notUp = Self.runningProviderLocalAPIFailure() {
                printError(Self.notUpLine(notUp.failure, nextFree: LocalAPIPort.nextFree(besides: notUp.failure.port),
                                          server: notUp.server))
            } else {
                printError("No local server running.")
                if let key = LocalEndpoint.existingClusterToken() {
                    // `darkbloom cluster local` with the API on the other Mac: the key is the same on both.
                    printError("The cluster's API key (the same on both Macs; `\(BuildEnvironment.current.cliName) cluster` shows where the API is):")
                    printError("  \(key)")
                } else {
                    for line in Self.notRunningHint { printError(line) }
                }
            }
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? encoder.encode(info)) ?? Data("{}".utf8)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        print("Local (direct-mode) OpenAI endpoint")
        print("  base URL: \(info.baseURL)")
        if let network = Self.networkURL(host: info.host, port: info.port) {
            // Listening on every interface (`darkbloom cluster local`'s default, or `--bind 0.0.0.0`).
            print("  network:  \(network) (or this Mac's LAN or tailnet address, same port; the API key is required)")
        }
        if info.apiKey.isEmpty {
            print("  API key:  (auth disabled)")
            print("  requests: this Mac only (without a local key nothing is passed on to your other Macs or the network)")
        } else {
            print("  API key:  \(info.apiKey)")
        }
        print("  pid:      \(info.pid)")
        // This record is this Mac's relay, which answers 503 while the pair's other Mac can't be reached.
        if pair.relaying?.port == info.port, let down = pair.memberAPIDown { print("Local API: " + down) }
        if let state = DaemonStateFile.read(), state.pid == info.pid {
            let route = (try? savedLocalSettings(configPath: nil))?.route
            for line in Self.servingLines(info: info, state: state, route: route,
                                          accountKeySaved: { Start.accountKeySaved() }) {
                print(line)
            }
        }
        if !info.apiKey.isEmpty { print(Self.toolsLine) }
        print()
        print("Use it with any OpenAI client:")
        print("  export OPENAI_BASE_URL=\(info.baseURL)")
        if !info.apiKey.isEmpty {
            print("  export OPENAI_API_KEY=\(info.apiKey)")
        }
        print()
        print("  curl \(info.baseURL)/chat/completions \\")
        if !info.apiKey.isEmpty {
            print("    -H 'Authorization: Bearer \(info.apiKey)' \\")
        }
        print("    -H 'Content-Type: application/json' \\")
        print("    -d '{\"model\":\"<id>\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
    }

    /// How the server behind `info` serves, and where your requests go when it can't take them; empty when the
    /// running provider's state isn't that server's (a cluster's API, or an older provider). A server without a key
    /// gets no requests line here: `run` has said "this Mac only" under its API key. `accountKeySaved` is asked only
    /// for the requests line. Never a key or a speed.
    static func servingLines(info: LocalEndpoint.Info, state: DaemonState?, route: LocalSettings.Route?,
                             accountKeySaved: () -> Bool) -> [String] {
        guard let state, state.pid == info.pid else { return [] }
        let serving: String
        if state.servesOnlyItsOwner {
            serving = LocalFirstWords.serving(mode: .local, meFirst: false, idleMinutes: 0)
        } else if let meFirst = state.meFirst {
            serving = LocalFirstWords.serving(mode: .both, meFirst: true,
                                              idleMinutes: LocalFirstWords.idleMinutes(milliseconds: meFirst.idleMs))
        } else {
            serving = LocalFirstWords.serving(mode: .both, meFirst: false, idleMinutes: 0)
        }
        guard !info.apiKey.isEmpty else { return ["  serving:  \(serving)"] }
        let keySaved = accountKeySaved()
        return ["  serving:  \(serving)",
                "  requests: \(LocalFirstWords.requests(route: route, accountKeySaved: keySaved))"
                    + (keySaved ? "" : " (`\(BuildEnvironment.current.cliName) route key` adds your other Macs)")]
    }

    /// What `local` says when the running provider's local API couldn't listen (`DaemonState.localAPIFailure`).
    static func notUpLine(_ failure: DaemonState.LocalAPIFailure, nextFree: UInt16?,
                          server: LocalFirstWords.LocalAPIServer = .singleMac(paired: false)) -> String {
        "The local API isn't up: " + LocalFirstWords.whyNotUp(failure, nextFree: nextFree, server: server) + "."
    }

    /// The running provider's local API that couldn't listen, and whose it is; nil when none runs or nothing failed.
    static func runningProviderLocalAPIFailure()
        -> (failure: DaemonState.LocalAPIFailure, server: LocalFirstWords.LocalAPIServer)? {
        guard let state = DaemonStateFile.read(), daemonProcessAlive(pid: state.pid),
              let failure = state.localAPIFailure else { return nil }
        return (failure, .of(state, paired: ClusterPairSummary.local().paired))
    }

    /// What `local` says to start a local API when none runs.
    static var notRunningHint: [String] {
        let cli = BuildEnvironment.current.cliName
        return ["Start one with:  \(cli) start --me-first   (Darkbloom and you, you first)",
                "             or: \(cli) start --local      (only you, on this Mac)"]
    }

    /// The line under a keyed server's address: the commands that set the tools up for it.
    static var toolsLine: String { "  tools:    \(BuildEnvironment.current.cliName) --opencode · --hermes" }

    /// For a server listening on every interface: this Mac's Bonjour (`.local`) URL, which other computers on the
    /// same network can dial; nil for a loopback or specific-address server, or when the Mac has no local host name.
    static func networkURL(host: String, port: UInt16) -> String? {
        guard host == "0.0.0.0" || host == "::",
              let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return "http://\(name).local:\(port)/v1"
    }
}
