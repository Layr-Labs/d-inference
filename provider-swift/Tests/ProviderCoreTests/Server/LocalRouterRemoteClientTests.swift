import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// A pair's API (Both, `cluster local`) listens on every network of its Mac, and so can a single Mac's with `--bind`:
/// anyone there with its key can name a model this Mac doesn't serve and have the request passed on with this Mac's
/// account key. The paid hop (`prefer`) serves only programs on this Mac. A client on another machine, known from its
/// connection's TCP peer and never from a header, gets `my-macs-first` as `my-macs`: your Macs only (`self`, free).
/// Each test drives the local API's whole responder stack on a connection whose peer it sets.
@Suite("Local router: requests from other machines never take the paid network")
struct LocalRouterRemoteClientTests {
    static let otherMachines = ["192.168.1.20", "10.0.0.7", "100.101.102.103", "2001:db8::20", "fe80::1"]
    /// Loopback: 127.0.0.0/8, ::1, and an IPv4 loopback peer as a dual-stack listener sees it.
    static let thisMac = ["127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"]

    /// `my-macs-first`, with a coordinator that answers everything: empty lists for the model reads, a completion for
    /// a passed-on request.
    static func fixture() -> RouterFixture {
        RouterFixture(route: .myMacsFirst) { request in
            request.method == "GET" ? .json(200, #"{"object":"list","data":[]}"#)
                : .json(200, #"{"id":"chatcmpl-up","object":"chat.completion","choices":[]}"#)
        }
    }

    @Test(arguments: otherMachines)
    func aRequestFromAnotherMachineGoesToYourMacsNeverToThePaidNetwork(peer: String) async throws {
        let fixture = Self.fixture()
        let answer = try await Self.respond(fixture, peer: peer, method: .post, path: "/v1/chat/completions",
                                            body: RouterFixture.chat("elsewhere"))
        #expect(answer.status == .ok, "\(peer)")
        #expect(answer.routeUsed == "self", "\(peer)")
        #expect(fixture.upstream.posts.map(\.route) == ["self"], "\(peer): never prefer")
    }

    @Test(arguments: thisMac)
    func aRequestFromThisMacKeepsMyMacsFirst(peer: String) async throws {
        let fixture = Self.fixture()
        let answer = try await Self.respond(fixture, peer: peer, method: .post, path: "/v1/chat/completions",
                                            body: RouterFixture.chat("elsewhere"))
        #expect(answer.status == .ok, "\(peer)")
        #expect(answer.routeUsed == "prefer", "\(peer)")
        #expect(fixture.upstream.posts.map(\.route) == ["prefer"], "\(peer)")
    }

    /// The model list names only what the client can reach: no network model for another machine.
    @Test func theModelListForAnotherMachineNamesNoNetworkModel() async throws {
        for (peer, networkReads) in [("192.168.1.20", 0), ("2001:db8::20", 0), ("127.0.0.1", 1), ("::1", 1)] {
            let fixture = Self.fixture()
            let answer = try await Self.respond(fixture, peer: peer, method: .get, path: "/v1/models", body: nil)
            #expect(answer.status == .ok, "\(peer)")
            let network = fixture.upstream.requests.filter { $0.method == "GET" && $0.url.path == "/v1/models" && $0.route == nil }
            #expect(network.count == networkReads, "\(peer): \(fixture.upstream.requests.map { "\($0.url.path) \($0.route ?? "-")" })")
        }
    }

    /// The local API's responder stack answering one request on a connection whose TCP peer is `peer`.
    static func respond(_ fixture: RouterFixture, peer: String, method: HTTPRequest.Method, path: String,
                        body: String?) async throws -> (status: HTTPResponse.Status, routeUsed: String?) {
        let channel = NIOAsyncTestingChannel()
        channel.remoteAddress = try SocketAddress(ipAddress: peer, port: 50_123)
        let context = LocalDisconnectContext(source: ApplicationRequestContextSource(
            channel: channel, logger: Logger(label: "local-router-remote-client")))
        var headers = RouterFixture.authorized
        let buffer = ByteBuffer(string: body ?? "")
        if body != nil { headers[.contentLength] = String(buffer.readableBytes) }
        let request = Request(head: .init(method: method, scheme: "http", authority: "localhost", path: path,
                                          headerFields: headers),
                              body: .init(buffer: buffer))
        let response = try await fixture.app.responder.respond(to: request, context: context)
        try await response.body.write(RouterRecordingWriter())
        try await channel.close()
        return (response.status, response.headers[LocalRouterPolicy.routeUsedHeader])
    }
}
