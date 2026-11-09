import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
import notify
@testable import ProviderCore

/// A request this Mac can't take, with a route that would pass it on but no account key: the saved `my-macs` or
/// `my-macs-first` with none saved, or the route a key gave until `darkbloom route key --remove` removed it while the
/// local API ran. The answer keeps this Mac's status and says why, and the log says it once per run; neither holds a
/// key. Without a chosen route and without a key ever seen, the answer is this Mac's own, as before. The router runs
/// over the stub engine and coordinator; nothing leaves the process.
@Suite("Local router: a route that needs a key without one")
struct LocalRouterMissingKeyTests {
    static var cli: String { BuildEnvironment.current.cliName }

    /// The error a client gets, as status, message and code.
    struct Refusal: Equatable {
        var status: HTTPResponse.Status
        var message: String?
        var code: String?
        var servedBy: String?
    }

    static func chat(_ client: some TestClientProtocol, _ model: String = "absent") async throws -> Refusal {
        var refusal = Refusal(status: .ok)
        try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                 body: ByteBuffer(string: RouterFixture.chat(model))) { response in
            let object = try? JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            refusal = Refusal(status: response.status, message: error?["message"] as? String,
                              code: error?["code"] as? String,
                              servedBy: response.headers[LocalRouterPolicy.servedByHeader])
        }
        return refusal
    }

    static func needsKey(_ status: HTTPResponse.Status, _ what: String, reach: String = "your other Macs") -> Refusal {
        Refusal(status: status, message: "\(what), and reaching \(reach) needs an account key: run `\(cli) route key`.",
                code: "account_key_needed", servedBy: "this-mac")
    }

    static func loggedNeedsKey(_ fixture: RouterFixture) -> [String] {
        fixture.log.lines.filter { $0.contains("needs an account key") }
    }

    @Test func aSavedRouteWithoutAKeySaysSoOnTheAnswerAndOnceInTheLog() async throws {
        let fixture = RouterFixture(route: .myMacs, key: nil)
        try await fixture.app.test(.router) { client in
            for _ in 0..<2 {
                let absent = try await Self.chat(client)
                #expect(absent == Self.needsKey(.notFound, "This Mac doesn't serve absent"))
            }
            let busy = try await Self.chat(client, "busy")
            #expect(busy == Self.needsKey(.tooManyRequests, "This Mac can't take this request right now"))
            let draining = try await Self.chat(client, "draining")
            #expect(draining == Self.needsKey(.serviceUnavailable, "This Mac can't take this request right now"))
        }
        #expect(fixture.upstream.requests.isEmpty)
        #expect(Self.loggedNeedsKey(fixture) == ["a request this Mac can't take stays on this Mac: reaching your other "
            + "Macs needs an account key, and none is saved (`\(Self.cli) route key` saves one)"])
    }

    @Test func myMacsFirstNamesTheNetworkToo() async throws {
        let fixture = RouterFixture(route: .myMacsFirst, key: nil)
        try await fixture.app.test(.router) { client in
            let absent = try await Self.chat(client)
            #expect(absent == Self.needsKey(.notFound, "This Mac doesn't serve absent",
                                            reach: "your other Macs or the Darkbloom network"))
        }
        #expect(Self.loggedNeedsKey(fixture).count == 1)
    }

    /// A client on another machine never uses the paid network, so its answer names your other Macs only.
    @Test func aClientOnAnotherMachineIsToldOfYourOtherMacsOnly() async throws {
        let fixture = RouterFixture(route: .myMacsFirst, key: nil)
        let answer = try await LocalRouterRemoteClientTests.respond(
            fixture, peer: "192.168.1.20", method: .post, path: "/v1/chat/completions", body: RouterFixture.chat("absent"))
        #expect(answer.status == .notFound)
        #expect(answer.body.contains("This Mac doesn't serve absent, and reaching your other Macs needs an account key"),
                "\(answer.body)")
        #expect(!answer.body.contains("Darkbloom network"))
        #expect(fixture.upstream.requests.isEmpty)
    }

    /// The route was unset, so the key alone made requests go on to your other Macs; `route key --remove` while the API
    /// runs keeps the next one here, and says why. A key saved again passes requests on, and a second removal is said
    /// again.
    @Test func aKeyRemovedWhileTheAPIRunsSaysWhyFromTheNextRequest() async throws {
        let fixture = RouterFixture(route: nil, key: RouterFixture.accountKey)
        let config = try #require(fixture.routerConfig)
        let stays = Self.needsKey(.notFound, "This Mac doesn't serve absent")
        try await fixture.app.test(.router) { client in
            let before = try await Self.chat(client)
            #expect(before.status == .ok)
            try await Self.changeKey(to: nil, fixture: fixture, config: config)
            let removed = try await Self.chat(client)
            #expect(removed == stays)
            try await Self.changeKey(to: RouterFixture.accountKey, fixture: fixture, config: config)
            let savedAgain = try await Self.chat(client)
            #expect(savedAgain.status == .ok)
            try await Self.changeKey(to: nil, fixture: fixture, config: config)
            let removedAgain = try await Self.chat(client)
            #expect(removedAgain == stays)
        }
        #expect(fixture.upstream.posts.map(\.route) == ["self", "self"])
        #expect(Self.loggedNeedsKey(fixture).count == 2, "\(fixture.log.lines)")
        #expect(!fixture.log.lines.joined(separator: "\n").contains(RouterFixture.accountKey))
    }

    /// Saves or removes the key as `route key` does, with its change notification, and waits until the router drops
    /// its copy.
    static func changeKey(to key: String?, fixture: RouterFixture, config: LocalRouterConfig) async throws {
        if let key { try fixture.keys.save(key) } else { try fixture.keys.remove() }
        notify_post(try #require(config.keyChangeNotification))
        #expect(await holdsWithinTwoSeconds { !config.keyCache.keepsACopy })
    }

    /// Nothing asked for your other Macs: no route chosen and no key seen while the API ran, or `this-mac`. The answer
    /// is this Mac's own, and nothing is logged.
    @Test func withoutARouteThatPassesRequestsOnTheAnswerIsThisMacsOwn() async throws {
        for route in [LocalSettings.Route?.none, .thisMac] {
            let fixture = RouterFixture(route: route, key: nil)
            try await fixture.app.test(.router) { client in
                let refusal = try await Self.chat(client)
                #expect(refusal.status == .notFound)
                #expect(refusal.code != "account_key_needed" && refusal.servedBy == "this-mac")
            }
            #expect(Self.loggedNeedsKey(fixture).isEmpty)
        }
    }
}
