import ArgumentParser
import Foundation
import NIOCore
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom route key [--stdin | --remove]`: the account key goes to the key store only, after one check with
/// Darkbloom, and no line `route key` says ever contains it. Every test uses an in-memory store and a stub
/// coordinator; the Keychain and the network are never touched.
@Suite("route key")
struct RouteKeyCommandTests {
    static let key = "sk-synthetic-route-key-5e1d0c9b8a7f6e5d"

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        func append(_ line: String) { lock.withLock { stored.append(line) } }
    }

    private func flow(_ check: RouteKeyCheck, route: LocalSettings.Route? = nil,
                      store: InMemoryLocalRouterAccountKeyStore = .init()) -> (RouteKeyFlow, Lines) {
        let lines = Lines()
        return (RouteKeyFlow(store: store, savedRoute: route, check: { _ in check }, say: { lines.append($0) }), lines)
    }

    @Test func theFlagsParseAndRefuseTogether() throws {
        _ = try Darkbloom.parseAsRoot(["route", "key", "--stdin"])
        _ = try Darkbloom.parseAsRoot(["route", "key", "--remove"])
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["route", "key", "--stdin", "--remove"]) }
    }

    @Test func anAcceptedKeyIsSavedAndNeverShown() async throws {
        let store = InMemoryLocalRouterAccountKeyStore()
        let (flow, lines) = flow(.accepted(models: 2), store: store)
        #expect(await flow.save("  \(Self.key)\n") == 0)
        #expect(try store.load() == Self.key)
        #expect(lines.all.first?.hasPrefix("✓ Account key saved in this Mac's Keychain.") == true)
        #expect(lines.all.contains("Your requests: this Mac first, then your other Macs (free)."))
        #expect(!lines.all.joined().contains(Self.key))
    }

    @Test func aRefusedKeyIsNotSaved() async throws {
        let store = InMemoryLocalRouterAccountKeyStore("sk-previous-key")
        let (flow, lines) = flow(.refused("invalid API key"), store: store)
        #expect(await flow.save(Self.key) == 1)
        #expect(try store.load() == "sk-previous-key")
        #expect(lines.all == ["✗ Darkbloom refused this key (invalid API key). Nothing was saved."])
    }

    @Test func aKeyThatCouldNotBeCheckedIsSavedWithANote() async throws {
        let store = InMemoryLocalRouterAccountKeyStore()
        let (flow, lines) = flow(.unchecked("this Mac is offline"), route: .myMacsFirst, store: store)
        #expect(await flow.save(Self.key) == 0)
        #expect(try store.load() == Self.key)
        #expect(lines.all.first?.contains("couldn't be checked with Darkbloom now (this Mac is offline)") == true)
        #expect(lines.all.contains { $0.contains("self-route-only key") })
        #expect(!lines.all.joined().contains(Self.key))
    }

    @Test(arguments: ["", "   ", "sk with space", "sk-é", String(repeating: "k", count: 513),
                      "dk-local-SyntheticRouterFixtureKeyAAAAAAAAAAAAAAAAAAAAAAAA"])
    func whatCannotBeAnAccountKeyIsRefusedBeforeAnyCheck(_ candidate: String) async throws {
        let store = InMemoryLocalRouterAccountKeyStore()
        let lines = Lines()
        let flow = RouteKeyFlow(store: store, savedRoute: nil, check: { _ in
            Issue.record("checked a key that was refused")
            return .accepted(models: 0)
        }, say: { lines.append($0) })
        #expect(await flow.save(candidate) == 1)
        #expect(try store.load() == nil)
        #expect(lines.all.first?.hasPrefix("✗ Not saved: ") == true)
    }

    @Test func removingTheKeyKeepsRequestsOnThisMac() throws {
        let store = InMemoryLocalRouterAccountKeyStore(Self.key)
        let (flow, lines) = flow(.accepted(models: 0), store: store)
        #expect(flow.remove() == 0)
        #expect(try store.load() == nil)
        #expect(lines.all == ["✓ Account key removed from this Mac's Keychain.",
                              "Your requests: this Mac only, until an account key is saved again."])
    }

    @Test func eachRouteIsSaidInPlainWordsWithoutSpeeds() {
        let all = [LocalSettings.Route?.none, .thisMac, .myMacs, .myMacsFirst].flatMap {
            RouteKeyFlow.routeLines(savedRoute: $0, keySaved: true) + RouteKeyFlow.routeLines(savedRoute: $0, keySaved: false)
        }.joined(separator: "\n")
        #expect(RouteKeyFlow.routeLines(savedRoute: .thisMac, keySaved: true).first?.contains("this Mac only") == true)
        #expect(RouteKeyFlow.routeLines(savedRoute: .myMacsFirst, keySaved: true).first?.contains("billed") == true)
        #expect(!all.contains("tok/s") && !all.lowercased().contains("tokens per second"))
    }

    @Test func theCheckAsksForTheOwnersModelsAndRedactsAnEcho() async throws {
        struct Stub: LocalRouterTransport {
            let status: Int
            let body: String
            let seen: Lines
            func send(_ request: LocalRouterUpstreamRequest) async throws -> LocalRouterUpstreamResponse {
                seen.append("\(request.method) \(request.url.absoluteString) route=\(request.headers["X-Darkbloom-Route"] ?? "-")")
                let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
                continuation.yield(ByteBuffer(string: body))
                continuation.finish()
                return .init(status: status, headers: [:], body: stream)
            }
        }
        let base = URL(string: "http://127.0.0.1:9")!
        let seen = Lines()
        #expect(await RouteKeyFlow.checkWithDarkbloom(key: Self.key, upstream: base, transport: Stub(
            status: 200, body: #"{"data":[{"id":"a"},{"id":"b"}]}"#, seen: seen)) == .accepted(models: 2))
        #expect(seen.all == ["GET http://127.0.0.1:9/v1/models route=self"])
        #expect(await RouteKeyFlow.checkWithDarkbloom(key: Self.key, upstream: base, transport: Stub(
            status: 401, body: #"{"error":{"message":"invalid API key \#(Self.key)"}}"#, seen: seen))
            == .refused("invalid API key [key]"))
        #expect(await RouteKeyFlow.checkWithDarkbloom(key: Self.key, upstream: base, transport: Stub(
            status: 500, body: "{}", seen: seen)) == .unchecked("Darkbloom answered HTTP 500"))
    }

    @Test func noFileOfTheInstallHoldsTheKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A local API's discovery record, as a host writes it, beside a saved key.
        let store = InMemoryLocalRouterAccountKeyStore()
        let (flow, _) = flow(.accepted(models: 1), store: store)
        #expect(await flow.save(Self.key) == 0)
        let info = LocalEndpoint.Info(host: "127.0.0.1", port: 8002, apiKey: "dk-local-fixture", version: "test",
                                      pid: 1, updatedAt: "now")
        let data = try JSONEncoder().encode(info)
        try data.write(to: directory.appendingPathComponent("local.json"))
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains(Self.key), "\(file)")
        }
    }
}
