import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
import notify
@testable import ProviderCore

/// A running local API uses a saved route and account key from its next request: `darkbloom route <choice>` and
/// `darkbloom route key` need no restart, so no model reloads for a routing change. The route is read again from the
/// provider config file when it changes; a file that doesn't read keeps the last good route and says so once. A
/// request this Mac serves never looks at the file. Every test runs the router over a stub engine and coordinator, with
/// a temporary provider.toml; nothing leaves the process.
@Suite("Local router: saved route and key, live")
struct LocalRouterLiveSettingsTests {
    /// A provider.toml in its own temporary folder, replaced as `setLocalSettings` replaces it (a new file each time).
    final class ConfigFile: Sendable {
        let folder: URL
        let url: URL

        init(_ text: String) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("router-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("provider.toml")
            try write(text)
        }

        convenience init(route: LocalSettings.Route) throws { try self.init(Self.text(route)) }

        static func text(_ route: LocalSettings.Route) -> String {
            "[provider]\nname = \"router-live\"\n\n[local]\nmode = \"both\"\nroute = \"\(route.rawValue)\"\n"
        }

        func write(_ text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
        func save(_ route: LocalSettings.Route) throws { try write(Self.text(route)) }
        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    /// The fixture's router reading `file`, as a host's reads its provider.toml.
    static func router(_ fixture: RouterFixture, file: ConfigFile) throws -> LocalRouterConfig {
        var config = try #require(fixture.routerConfig)
        config.settingsFile = file.url
        return config
    }

    static func app(_ fixture: RouterFixture, router: LocalRouterConfig) -> LocalInferenceApplication {
        RouterFixture.makeApp(router: router, engine: fixture.engine, localModels: fixture.localModels)
    }

    /// One chat for `model`; returns its status and the route the coordinator was asked with (nil: not passed on).
    static func chat(_ client: some TestClientProtocol, _ model: String = "absent", upstream: RouterStubUpstream)
        async throws -> (HTTPResponse.Status, String?) {
        let before = upstream.posts.count
        var status = HTTPResponse.Status.ok
        try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                 body: ByteBuffer(string: RouterFixture.chat(model))) { response in
            status = response.status
        }
        return (status, upstream.posts.count > before ? upstream.posts.last?.route : nil)
    }

    @Test func aSavedRouteIsUsedOnTheNextRequestWithNoRestart() async throws {
        let file = try ConfigFile(route: .thisMac)
        let fixture = RouterFixture(route: .thisMac)
        let router = try Self.router(fixture, file: file)
        try await Self.app(fixture, router: router).test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
            try file.save(.myMacs)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try file.save(.myMacsFirst)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "prefer"))
            try file.save(.thisMac)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
        }
        #expect(fixture.log.lines.contains("route is now my-macs (provider.toml changed)"))
        #expect(fixture.log.lines.contains("route is now my-macs-first (provider.toml changed)"))
        #expect(fixture.log.lines.contains("route is now this-mac (provider.toml changed)"))
    }

    @Test func theModelListFollowsTheSavedRouteToo() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs) { request in
            request.method == "GET" && request.url.path == "/v1/models" && request.route == nil
                ? .json(200, #"{"object":"list","data":[{"id":"big","owned_by":"darkbloom"}]}"#)
                : .json(200, #"{"object":"list","data":[]}"#)
        }
        let router = try Self.router(fixture, file: file)
        try await Self.app(fixture, router: router).test(.router) { client in
            #expect(try await !Self.networkListed(client))
            try file.save(.myMacsFirst)
            #expect(try await Self.networkListed(client))
        }
    }

    /// Whether the local `/v1/models` lists a network model.
    static func networkListed(_ client: some TestClientProtocol) async throws -> Bool {
        var listed = false
        try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
            let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
            listed = list.data.contains { $0.ownedBy == "darkbloom" }
        }
        return listed
    }

    /// The key was already read again after `route key`'s notification; with the route read from the file, a key saved
    /// while the route is `my-macs` passes the next request on, and a key removed keeps the next one on this Mac.
    @Test func aKeySavedOrRemovedWhileRunningCountsFromTheNextRequest() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs, key: nil)
        let router = try Self.router(fixture, file: file)
        let notification = try #require(router.keyChangeNotification)
        try await Self.app(fixture, router: router).test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
            try fixture.keys.save(RouterFixture.accountKey)
            notify_post(notification)
            #expect(await holdsWithinTwoSeconds { !router.keyCache.keepsACopy })
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try fixture.keys.remove()
            notify_post(notification)
            #expect(await holdsWithinTwoSeconds { !router.keyCache.keepsACopy })
            // This Mac's own answer, as without a key: its 404, served by this Mac.
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[LocalRouterPolicy.servedByHeader] == "this-mac")
            }
        }
        #expect(fixture.upstream.posts.map(\.route) == ["self"])
        #expect(!fixture.log.lines.joined(separator: "\n").contains(RouterFixture.accountKey))
    }

    @Test func aMalformedEditKeepsTheLastGoodRouteAndSaysSoOnce() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs)
        let router = try Self.router(fixture, file: file)
        let kept = "provider.toml doesn't read as a provider config now; requests keep the route my-macs until it does"
        try await Self.app(fixture, router: router).test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try file.write("[local]\nmode = \"both\"\nroute = \"everywhere\"\n")
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try file.write("[local\nroute = ")
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            #expect(fixture.log.lines.filter { $0 == kept }.count == 1, "\(fixture.log.lines)")
            try file.save(.myMacsFirst)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "prefer"))
        }
        #expect(fixture.log.lines.contains("route is now my-macs-first (provider.toml changed)"))
        #expect(!fixture.log.lines.joined(separator: "\n").contains("everywhere"))
    }

    @Test func aRequestThisMacServesNeverLooksAtTheFile() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs)
        let router = try Self.router(fixture, file: file)
        try await Self.app(fixture, router: router).test(.router) { client in
            for _ in 0..<5 { #expect(try await Self.chat(client, "here", upstream: fixture.upstream) == (.ok, nil)) }
            #expect(router.routeFile.checks == 0)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            #expect(router.routeFile.checks == 1)
            try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                #expect(response.status == .ok)
            }
            #expect(router.routeFile.checks == 2)
        }
    }

    /// The file is read again only when it changed (one `stat` a call otherwise); a file that is gone keeps the last
    /// good route and is said once; one that comes back is read again.
    @Test func theFileIsReadAgainOnlyWhenItChanges() throws {
        let file = try ConfigFile(route: .myMacs)
        let routes = LocalRouterRouteFile()
        let reads = RouterLogLines(), log = RouterLogLines()
        func route() -> LocalSettings.Route? {
            routes.route(in: file.url, startingWith: .thisMac, log: { log.append($0) }, read: { url in
                reads.append(url.lastPathComponent)
                return try ConfigManager.load(from: url).local?.route
            })
        }
        #expect(route() == .myMacs)
        #expect(route() == .myMacs)
        #expect(reads.lines.count == 1)
        try file.save(.myMacsFirst)
        #expect(route() == .myMacsFirst)
        #expect(reads.lines.count == 2)
        try FileManager.default.removeItem(at: file.url)
        #expect(route() == .myMacsFirst)
        #expect(route() == .myMacsFirst)
        #expect(log.lines.filter { $0.hasPrefix("provider.toml doesn't read") }.count == 1)
        try file.save(.thisMac)
        #expect(route() == .thisMac)
        #expect(routes.checks == 6)
        #expect(reads.lines.count == 4)
    }
}
