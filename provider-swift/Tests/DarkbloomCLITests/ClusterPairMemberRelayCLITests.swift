import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Every Mac of a pair answers locally (Both, me first as `cluster local`): a Mac whose part isn't rank 0 relays its own
/// port to the pair's API, so its own `status`, `darkbloom local` and `start --opencode` name an address on this Mac,
/// with this Mac's own key. No pair, cluster service, port or tool runs: the pair is a summary value and the tools a
/// scripted step in a temp home.
@Suite("A pair's every Mac answers locally (CLI)", .serialized)
struct ClusterPairMemberRelayCLITests {
    typealias F = LocalFirstStatusFixtures
    static let other = "the other Mac (Apple M5 Ultra, 256 GB)"

    /// A member (its part isn't rank 0) of a pair serving Both, me first, with the pair's API on `bind`.
    private func member(relaying: ClusterPairLocalAPI.Address? = .init(host: "0.0.0.0", port: 8003),
                        bind: String? = "0.0.0.0") -> ClusterPairSummary {
        var pair = ClusterPairSummary(paired: true, role: .member, otherMacName: "Apple M5 Ultra, 256 GB", modelID: "qwen",
                                      modelName: "Qwen 3.8 27B", started: true, serviceRunning: true, state: .serving)
        pair.lines = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."]
        pair.localAPI = ClusterPairLocalAPI(runsRankZero: false, listening: nil, meFirst: nil)
        pair.localAPIBind = bind
        pair.relaying = relaying
        return pair
    }

    // MARK: - status

    /// The member's `status` names the address its tools dial on this Mac, and where its requests go.
    @Test func aMembersStatusNamesItsOwnAddress() {
        let passes = "Members: \(Self.other) runs the pair's API; this Mac passes your requests to it, and Darkbloom pauses for them too"
        #expect(member().localAPILines(now: F.now, timeZone: F.utc) == [
            "Local API: http://127.0.0.1:8003/v1 on this Mac, and port 8003 of its LAN or tailnet address (`\(ClusterPairSummary.cli) local` shows the key)",
            passes,
        ])
        #expect(member().clusterStatusLines.contains { $0.hasPrefix("Local API: http://127.0.0.1:8003/v1 on this Mac") })
        // Its relay isn't up yet (the pair's API is still starting on the other Mac).
        #expect(member(relaying: nil).localAPILines(now: F.now, timeZone: F.utc) == [
            "Local API: not listening on this Mac yet; it starts once the pair's API on \(Self.other) answers", passes,
        ])
        // The pair's API kept on its own Mac (loopback or one address): nothing relays it, as before.
        for bind in ["127.0.0.1", "192.168.1.5"] {
            #expect(member(relaying: nil, bind: bind).localAPILines(now: F.now, timeZone: F.utc) == [
                "Local API: on \(Self.other), which runs the pair's API; `\(ClusterPairSummary.cli) local` there shows its address "
                    + "and key, and `\(ClusterPairSummary.cli) status` there whether Darkbloom is paused for you",
                "Members: this Mac is part of the pair; it runs no local API",
            ], "\(bind)")
        }
    }

    /// The Mac that runs the pair's API says the other Mac answers on its own port too, once the API is on every address.
    @Test func theLeadersStatusSaysTheOtherMacAnswersToo() {
        func leader(_ host: String) -> ClusterPairSummary {
            var pair = ClusterPairSummary(paired: true, role: .leader, otherMacName: "Apple M3 Ultra, 256 GB", modelID: "qwen",
                                          modelName: "Qwen 3.8 27B", started: true, serviceRunning: true, state: .serving)
            pair.localAPI = ClusterPairLocalAPI(runsRankZero: true, listening: .init(host: host, port: 8003), meFirst: F.open)
            pair.localAPIBind = host
            return pair
        }
        #expect(leader("0.0.0.0").localAPILines(now: F.now, timeZone: F.utc).last
            == "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; its own port passes your requests to this API")
        #expect(leader("127.0.0.1").localAPILines(now: F.now, timeZone: F.utc).last
            == "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API")
    }

    /// This Mac's relay is the discovery record its own cluster service wrote: not its part's, and not another server's.
    @Test func thisMacsRelayIsTheRecordItsClusterServiceWrote() throws {
        var own = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(
            #"{"serving":true,"sessionLeader":false,"child":{"running":true,"starts":1,"pid":5000},"servicePID":4242}"#.utf8))
        func record(pid: Int32, host: String = "0.0.0.0") -> LocalEndpoint.Info {
            LocalEndpoint.Info(host: host, port: 8003, apiKey: "dk-local-k", version: "t", pid: pid, updatedAt: "")
        }
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 4242)) == .init(host: "0.0.0.0", port: 8003))
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 5000)) == nil, "its part's API is not a relay")
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 77)) == nil, "another server")
        #expect(ClusterPairSummary.relayAddress(own: own, live: nil) == nil)
        own.servicePID = nil
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 4242)) == nil, "an older service says no pid")
        #expect(ClusterPairSummary.relayAddress(own: nil, live: record(pid: 4242)) == nil)
    }

    // MARK: - darkbloom local

    /// `darkbloom local` on a member prints its relay's address on this Mac and this Mac's own key, which is the key
    /// file its tools read (`local_token`); the pair's key is never the one shown.
    @Test func localOnAMemberPrintsItsOwnAddressAndKey() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("member-relay-local-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
            let own = "dk-local-MemberOwnKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            let pair = "dk-local-PairKeyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
            try own.write(to: directory.appendingPathComponent("local_token"), atomically: true, encoding: .utf8)
            try pair.write(to: directory.appendingPathComponent("cluster_local_token"), atomically: true, encoding: .utf8)
            try LocalEndpoint.writeInfo(ClusterService.relayDiscovery(port: 8003, keys: .init(own: own, pair: pair)))
            var command = try Local.parse([])
            try await command.run()
            let keyFile = LocalEndpoint.keyFile(forPort: 8003)?.lastPathComponent
            print("---key file: \(keyFile ?? "none")")
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        }
        let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
        #expect(stdout.contains("  base URL: http://127.0.0.1:8003/v1\n"), "\(stdout)")
        #expect(stdout.contains("  API key:  dk-local-MemberOwnKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"), "\(stdout)")
        #expect(!stdout.contains("PairKey"), "never the pair's key")
        #expect(stdout.contains("---key file: local_token"), "tools read this Mac's own key file")
    }

    // MARK: - start --opencode on a member

    /// The tools on a member point at its own relay, with its own key file, and say where its requests go: to the pair,
    /// never the paid network (rank 0's API sees another machine).
    @Test func startOpenCodeOnAMemberSetsItUpForItsOwnRelay() async throws {
        let sandbox = try ToolSandbox()
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8003/v1", keyFile: sandbox.keyFile)
        let start = try Start.parse(["--opencode", "--config", sandbox.config.path])
        try await start.setUpToolsBesidePair(pair: member(), waitForAPI: { .ready(endpoint) }, step: sandbox.step())
        let written = String(decoding: try Data(contentsOf: sandbox.openCodeFile), as: UTF8.self)
        #expect(written.contains("http://127.0.0.1:8003/v1"))
        #expect(written.contains("{file:~/.darkbloom/local_token}"))
        #expect(sandbox.fetched == [endpoint], "the models were read through this Mac's own API")
        #expect(sandbox.said.contains("  Requests: the pair, on its API on the other Mac; never the paid Darkbloom network"),
                "\(sandbox.said)")
        #expect(!sandbox.said.joined().contains(sandbox.token), "no key printed")
    }

    /// A pair that serves only Darkbloom, an API kept on the other Mac, or an API that doesn't answer in time: one line
    /// that says why and what to do, nothing written, and the start fails while the pair keeps serving.
    @Test func aMemberWithoutItsOwnAPISaysWhyAndWritesNothing() async throws {
        var network = member(relaying: nil, bind: nil)
        network.localAPI = nil
        for pair in [network, member(relaying: nil, bind: "127.0.0.1"), member(relaying: nil)] {
            let sandbox = try ToolSandbox()
            await #expect(throws: ExitCode.failure) {
                try await Start.parse(["--opencode", "--config", sandbox.config.path])
                    .setUpToolsBesidePair(pair: pair, waitForAPI: { sandbox.waited(); return .notUp }, step: sandbox.step())
            }
            #expect(sandbox.said.isEmpty && !FileManager.default.fileExists(atPath: sandbox.openCodeFile.path))
            #expect(sandbox.waits == (pair.localAPIBind == nil ? 0 : 1), "a pair with no local API anywhere doesn't wait")
        }
        #expect(ToolIntegrationStep.noPairAPI([.opencode]) == "✗ This pair serves only the Darkbloom network, so OpenCode "
            + "has no local address to use and wasn't set up. In `darkbloom cluster`, Change how the pair serves to "
            + "\"Both, me first\" or \"Only me\", then run `darkbloom start --opencode` again.")
        #expect(ToolIntegrationStep.pairAPIElsewhere([.opencode], bind: "127.0.0.1") == "✗ The pair's local API listens "
            + "on the Mac that runs it only (127.0.0.1), so OpenCode wasn't set up on this Mac: run `darkbloom start "
            + "--opencode` on that Mac.")
    }

    // MARK: - The leading part's keys

    /// The part that runs the pair's API takes this Mac's own key (its tools' key) and the pair's (every relay's);
    /// either one that can't be read keeps the API closed and Darkbloom serving.
    @Test func theLeadingPartTakesItsOwnKeyAndThePairs() {
        var said: [String] = []
        let leader = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8003,
            local: nil, coordinatorURL: nil, loadToken: { "dk-local-own" }, loadPairToken: { "dk-local-pair" },
            say: { said.append($0) })
        #expect(leader?.authToken == "dk-local-own")
        #expect(leader?.pairToken == "dk-local-pair")
        #expect(said.isEmpty)
        for (own, pair) in [(false, true), (true, false)] {
            let closed = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8003,
                local: nil, coordinatorURL: nil,
                loadToken: { if own { return "dk-local-own" }; throw CocoaError(.fileReadNoPermission) },
                loadPairToken: { if pair { return "dk-local-pair" }; throw CocoaError(.fileReadNoPermission) },
                say: { said.append($0) })
            #expect(closed == nil, "own key read: \(own), pair key read: \(pair)")
        }
        #expect(said.count == 2)
    }
}

/// A temp home with this Mac's key file and a provider config, and a scripted tool step that records what it read and
/// said. No tool runs, no port is bound, and no real home or tool config is touched.
private final class ToolSandbox: @unchecked Sendable {
    let directory: TemporaryDirectory
    let token = ToolIntegrationFixtures.freshToken()
    let home: URL
    let keyFile: URL
    let config: URL
    private let lock = NSLock()
    private var lines: [String] = []
    private var reads: [IntegrationEndpoint] = []
    private var waitCount = 0

    init() throws {
        directory = try TemporaryDirectory("member-relay-tools")
        home = directory.file("home")
        keyFile = try directory.write(token, to: "home/.darkbloom/local_token", mode: 0o600)
        config = try directory.write("[provider]\nname = \"member\"\n\n[local]\nroute = \"my-macs-first\"\n", to: "provider.toml")
    }

    var said: [String] { lock.withLock { lines } }
    var fetched: [IntegrationEndpoint] { lock.withLock { reads } }
    /// How often the start waited for this Mac's local API.
    var waits: Int { lock.withLock { waitCount } }
    func waited() { lock.withLock { waitCount += 1 } }
    var openCodeFile: URL { home.appendingPathComponent(".config/opencode/opencode.jsonc") }

    func step() -> ToolIntegrationStep {
        ToolIntegrationStep(
            tools: [.opencode], environment: ToolIntegrationEnvironment(home: home, variables: [:]),
            provider: ToolIntegrationFixtures.provider,
            findTool: { _ in .installed(URL(fileURLWithPath: "/fake/opencode")) },
            fetchModels: { endpoint in
                self.lock.withLock { self.reads.append(endpoint) }
                return [EndpointModel(id: "qwen3.8-27b", ownedBy: "this-mac", contextLength: 131_072)]
            },
            fetchCatalog: { nil },
            say: { line in self.lock.withLock { self.lines.append(line) } })
    }
}
