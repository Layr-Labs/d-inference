import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import ProviderCore

/// A pair's leader API run by `darkbloom start --local --distributed`: `cluster local`, and the leader's own API while
/// the pair isn't offered to Darkbloom, registered with the coordinator or fallen back to serving locally (L3 review,
/// nit 4). It takes no Darkbloom work in any of these, so its router never asks the coordinator's `self` view: the view
/// doesn't count this leader, and with exactly one other Mac of the owner's serving the model it would read as none and
/// answer a false `this_mac_only`.
@Suite("Local router: a pair's leader outside Darkbloom")
struct LocalRouterPairLeaderTests {
    @Test func aRequestThePairCantTakeGoesToYourOtherMacWithoutAskingTheSelfView() async throws {
        // One other Mac of the owner's serves `busy`, so the coordinator's `self` view counts 1 (never this leader).
        let upstream = RouterStubUpstream { request in
            request.method == "GET" ? .json(200, #"{"id":"busy","owned_by":"self","metadata":{"provider_count":1}}"#)
                : .json(200, #"{"id":"chatcmpl-up","object":"chat.completion","choices":[]}"#)
        }
        let factory = RouterTransportFactory(upstream)
        var router = LocalRouterConfig.pairLeaderOutsideDarkbloom(local: LocalSettings(route: .myMacs),
                                                                  coordinatorURL: "ws://127.0.0.1:1/ws/provider")
        #expect(!router.takesCoordinatorWork)
        router.accountKeys = InMemoryLocalRouterAccountKeyStore(RouterFixture.accountKey)
        router.makeTransport = { factory.make() }
        router.log = { _ in }
        let app = RouterFixture.makeApp(router: router, engine: RouterStubEngine(), localModels: RouterStubEngine.servedModels)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("busy"))) { response in
                #expect(response.status == .ok)
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "self")
                #expect(!String(buffer: response.body).contains("this_mac_only"))
            }
        }
        // Passed on once, to `self`, and the `self` view never read.
        #expect(upstream.requests.map(\.method) == ["POST"])
        #expect(upstream.posts.map(\.route) == ["self"])
    }

    /// The router's coordinator and `[local]` are the ones any host's has.
    @Test func itReadsLocalAndTheCoordinatorAsAnyHostsRouter() {
        let local = LocalSettings(route: .myMacsFirst)
        let router = LocalRouterConfig.pairLeaderOutsideDarkbloom(local: local, coordinatorURL: "wss://coordinator.example/ws/provider")
        let host = LocalRouterConfig.host(local: local, coordinatorURL: "wss://coordinator.example/ws/provider", takesCoordinatorWork: false)
        #expect(router.settings == host.settings && router.upstreamBaseURL == host.upstreamBaseURL)
    }
}
