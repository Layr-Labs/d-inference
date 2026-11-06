import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MLXLMServer
import NIOCore
import NIOFoundationCompat
import Testing
@testable import ProviderCore

/// The local router (`LocalRouter`): this Mac first, then the owner's other Macs, then the network if chosen. Every
/// test runs in process with this Mac's engine and the coordinator both stubbed; nothing dials out.
@Suite("Local router")
struct LocalRouterTests {
    // MARK: - Decisions

    @Test func theUpstreamIsTheConfiguredCoordinatorOverHTTP() {
        func base(_ url: String?) -> String { LocalRouterPolicy.upstreamBaseURL(coordinatorURL: url).absoluteString }
        #expect(base("ws://h:8080/ws/provider") == "http://h:8080")
        #expect(base("wss://api.darkbloom.dev/ws/provider") == "https://api.darkbloom.dev")
        #expect(base("ws://127.0.0.1:18089/ws/provider/") == "http://127.0.0.1:18089")
        #expect(base("https://api.dev.darkbloom.dev/") == "https://api.dev.darkbloom.dev")
        #expect(base("WSS://Example.test/ws/provider?x=1") == "https://Example.test")
        for fallback in [nil, "", "   ", "not a url", "ftp://h/ws/provider", "ws:///ws/provider"] {
            #expect(base(fallback) == BuildEnvironment.current.coordinatorHTTPURL, "\(String(describing: fallback))")
        }
    }

    @Test func eachRouteHasItsHopsAndOnlyThisMacsInabilityPassesARequestOn() {
        #expect(LocalRouterPolicy.hops(for: .thisMac).isEmpty)
        #expect(LocalRouterPolicy.hops(for: .myMacs) == [.mine])
        #expect(LocalRouterPolicy.hops(for: .myMacsFirst) == [.mine, .prefer])
        #expect(LocalRouterUpstreamRoute.mine.rawValue == "self")
        for status: HTTPResponse.Status in [.notFound, .tooManyRequests, .serviceUnavailable] {
            #expect(LocalRouterPolicy.passesOn(localStatus: status), "\(status)")
        }
        for status: HTTPResponse.Status in [.ok, .badRequest, .unauthorized, .contentTooLarge, .unprocessableContent,
                                             .internalServerError, .notImplemented, .gatewayTimeout,
                                             .init(code: 499)] {
            #expect(!LocalRouterPolicy.passesOn(localStatus: status), "\(status)")
        }
        #expect([409, 429, 503].allSatisfy(LocalRouterPolicy.triesNextHop(after:)))
        #expect(![200, 400, 401, 402, 403, 413, 500, 502, 504].contains(where: LocalRouterPolicy.triesNextHop(after:)))
        #expect(LocalRouterPolicy.upstreamPath(forLocalPath: "/chat/completions") == "/v1/chat/completions")
        #expect(LocalRouterPolicy.upstreamPath(forLocalPath: "/completions") == "/v1/completions")
        #expect(LocalRouterPolicy.upstreamPath(forLocalPath: "/responses") == "/v1/responses")
        for local in ["/v1/embeddings", "/v1/chat/completions/batch", "/tokenize", "/v1/models", "/v1/messages"] {
            #expect(LocalRouterPolicy.upstreamPath(forLocalPath: local) == nil, "\(local)")
        }
    }

    // MARK: - Fallback

    @Test(arguments: [(model: "absent", status: HTTPResponse.Status.notFound),
                      (model: "busy", status: HTTPResponse.Status.tooManyRequests),
                      (model: "draining", status: HTTPResponse.Status.serviceUnavailable)],
          [false, true])
    func eachFallbackTriggerMakesExactlyOneUpstreamCallWithTheRouteHeader(
        trigger: (model: String, status: HTTPResponse.Status), stream: Bool) async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"up\"}}]}\n\ndata: [DONE]\n\n"
        let fixture = RouterFixture(route: .myMacs) { _ in
            stream ? .init(status: 200, headers: ["content-type": "text/event-stream", "x-provider-id": "p-1"],
                           chunks: [sse])
                : .json(200, #"{"id":"chatcmpl-up","choices":[]}"#)
        }
        let body = RouterFixture.chat(trigger.model, stream: stream)
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: body)) { response in
                #expect(response.status == .ok)
                #expect(response.headers[LocalRouterPolicy.servedByHeader] == "darkbloom")
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "self")
                #expect(response.headers[.accessControlAllowOrigin] == "*")
                #expect(response.headers[HTTPField.Name("X-Provider-Id")!] == nil)
                #expect(String(buffer: response.body) == (stream ? sse : #"{"id":"chatcmpl-up","choices":[]}"#))
            }
        }
        let posts = fixture.upstream.posts
        #expect(posts.count == 1)
        #expect(posts.first?.url.absoluteString == "http://coordinator.invalid:8080/v1/chat/completions")
        #expect(posts.first?.route == "self")
        #expect(posts.first?.headers["Authorization"] == "Bearer \(RouterFixture.accountKey)")
        #expect(posts.first?.bodyText == body)
        #expect(fixture.factory.count == 1)
        #expect(fixture.log.lines.first == "this Mac answered \(trigger.status.code); passing the request on (self)")
    }

    @Test func everyRoutedPathPassesOnToItsCoordinatorPath() async throws {
        let fixture = RouterFixture(route: .myMacs)
        try await fixture.app.test(.router) { client in
            for (path, body) in [("/chat/completions", RouterFixture.chat("absent")),
                                 ("/v1/completions", #"{"model":"absent","prompt":"hi"}"#),
                                 ("/v1/responses", #"{"model":"absent","input":"hi"}"#)] {
                try await client.execute(uri: path, method: .post, headers: RouterFixture.authorized,
                                         body: ByteBuffer(string: body)) { response in
                    #expect(response.status == .ok, "\(path)")
                }
            }
        }
        #expect(fixture.upstream.posts.map(\.url.path) == ["/v1/chat/completions", "/v1/completions", "/v1/responses"])
    }

    @Test func clientErrorsABadLocalKeyAndAnythingAfterTheFirstByteNeverGoUpstream() async throws {
        let fixture = RouterFixture(route: .myMacsFirst)
        try await fixture.app.test(.router) { client in
            for (model, status) in [("bad", HTTPResponse.Status.badRequest), ("boom", .internalServerError)] {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                         body: ByteBuffer(string: RouterFixture.chat(model))) { response in
                    #expect(response.status == status, "\(model)")
                    #expect(response.headers[LocalRouterPolicy.servedByHeader] == "this-mac")
                }
            }
            // A local key that is wrong: the router is never reached.
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                                     headers: [.contentType: "application/json", .authorization: "Bearer dk-local-wrong"],
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status == .unauthorized)
            }
            // Malformed JSON is this Mac's 400.
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: "{not json")) { response in
                #expect(response.status == .badRequest)
            }
            // A stream that fails after its first byte ends as this Mac's stream: no switch mid-stream.
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("cut", stream: true))) { response in
                #expect(response.status == .ok)
                #expect(response.headers[LocalRouterPolicy.servedByHeader] == "this-mac")
                #expect(String(buffer: response.body).contains("hi"))
            }
        }
        #expect(fixture.upstream.requests.isEmpty)
        #expect(fixture.factory.count == 0)
    }

    @Test(arguments: [
        (503, #"{"error":{"type":"machine_offline","message":"your machine is offline","code":"machine_offline"}}"#, "30"),
        (409, #"{"error":{"type":"no_linked_machine","message":"no machine is linked","code":"no_linked_machine"}}"#, nil),
        (429, #"{"error":{"type":"machine_busy","message":"your machine is busy","code":"machine_busy"}}"#, "2"),
        (402, #"{"error":{"type":"insufficient_quota","message":"promotion limit","code":"insufficient_quota"}}"#, nil),
    ] as [(Int, String, String?)])
    func upstreamRefusalsComeBackVerbatim(status: Int, body: String, retryAfter: String?) async throws {
        let fixture = RouterFixture(route: .myMacs) { _ in .json(status, body, retryAfter: retryAfter) }
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status.code == status)
                #expect(String(buffer: response.body) == body)
                #expect(response.headers[.retryAfter] == retryAfter)
                #expect(response.headers[.contentType] == "application/json")
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "self")
            }
        }
        // `self` is never upgraded to `prefer`.
        #expect(fixture.upstream.posts.map(\.route) == ["self"])
    }

    @Test func myMacsFirstTriesTheOwnersMacsBeforeTheNetwork() async throws {
        for (selfStatus, expected) in [(200, ["self"]), (503, ["self", "prefer"]), (409, ["self", "prefer"]),
                                       (429, ["self", "prefer"]), (400, ["self"])] {
            let fixture = RouterFixture(route: .myMacsFirst) { request in
                request.route == "self" ? .json(selfStatus, #"{"error":{"message":"from self"}}"#)
                    : .json(200, #"{"id":"from-prefer"}"#)
            }
            try await fixture.app.test(.router) { client in
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                         body: ByteBuffer(string: RouterFixture.chat("busy"))) { response in
                    if expected.count == 2 {
                        #expect(response.status == .ok)
                        #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "prefer")
                    } else {
                        #expect(response.status.code == selfStatus)
                        #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "self")
                    }
                }
            }
            #expect(fixture.upstream.posts.map(\.route) == expected, "self answered \(selfStatus)")
        }
    }

    @Test func aBalanceRefusalOnTheNetworkHopSaysSoPlainly() async throws {
        let coordinatorMessage = "your balance is too low for this request — add funds at /billing or lower max_tokens"
        let fixture = RouterFixture(route: .myMacsFirst) { request in
            request.route == "self"
                ? .json(503, #"{"error":{"type":"machine_offline","message":"offline","code":"machine_offline"}}"#,
                        retryAfter: "30")
                : .json(402, #"{"error":{"type":"insufficient_funds","message":"\#(coordinatorMessage)","code":"insufficient_quota"}}"#,
                        retryAfter: "60")
        }
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status.code == 402)
                #expect(response.headers[.retryAfter] == "60")
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "prefer")
                let error = try #require(try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                    as? [String: Any])["error"] as? [String: Any]
                #expect(error?["code"] as? String == "insufficient_quota")
                #expect(error?["type"] as? String == "insufficient_funds")
                let message = try #require(error?["message"] as? String)
                #expect(message.hasPrefix("No balance for the network fallback: "))
                #expect(message.hasSuffix(coordinatorMessage))
            }
        }
        #expect(fixture.upstream.posts.map(\.route) == ["self", "prefer"])
    }

    @Test func theClientsRouteHeaderAndKeyNeverReachTheCoordinator() async throws {
        let fixture = RouterFixture(route: .myMacs)
        var clientHeaders = RouterFixture.authorized
        clientHeaders[LocalRouterPolicy.routeHeader] = "prefer"
        clientHeaders[HTTPField.Name("X-Custom-Tool")!] = "opencode"
        clientHeaders[.cookie] = "session=fixture"
        let headers = clientHeaders
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status == .ok)
            }
        }
        let sent = try #require(fixture.upstream.posts.first)
        #expect(sent.route == "self")
        #expect(sent.headers["Authorization"] == "Bearer \(RouterFixture.accountKey)")
        #expect(!sent.headers.values.contains { $0.contains(RouterFixture.localKey) })
        #expect(Set(sent.headers.keys) == ["Authorization", "X-Darkbloom-Route", "Content-Type", "Accept",
                                           "Accept-Encoding", "User-Agent"])
    }

    @Test func theAccountKeyAppearsInNoResponseAndNoLogLine() async throws {
        let key = RouterFixture.accountKey
        let scripts: [@Sendable (LocalRouterUpstreamRequest) throws -> RouterStubUpstream.Answer] = [
            { _ in .json(200, #"{"ok":true}"#) },
            { _ in .json(503, #"{"error":{"message":"echo \#(key)","code":"machine_offline"}}"#) },
            { _ in .json(401, #"{"error":{"message":"invalid API key \#(key)","type":"authentication_error"}}"#) },
            { _ in throw LocalRouterUpstreamError.unreachable("Darkbloom refused the connection") },
        ]
        for script in scripts {
            let fixture = RouterFixture(route: .myMacsFirst, upstream: script)
            try await fixture.app.test(.router) { client in
                for path in ["/v1/chat/completions", "/v1/models"] {
                    let get = path == "/v1/models"
                    try await client.execute(uri: path, method: get ? .get : .post, headers: RouterFixture.authorized,
                                             body: get ? nil : ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                        #expect(!String(buffer: response.body).contains(key))
                        #expect(!response.headers.contains { $0.value.contains(key) })
                    }
                }
            }
            #expect(!fixture.log.lines.joined(separator: "\n").contains(key))
            #expect(!fixture.log.lines.isEmpty)
        }
    }

    @Test func aRefusedAccountKeyIsThisMacsProblemNotTheClients() async throws {
        let fixture = RouterFixture(route: .myMacs) { _ in
            .json(401, #"{"error":{"message":"invalid API key","type":"authentication_error"}}"#)
        }
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status == .badGateway)
                let text = String(buffer: response.body)
                #expect(text.contains("account_key_refused"))
                #expect(text.contains("route key"))
            }
        }
    }

    @Test func anUnreachableCoordinatorIsAClearError() async throws {
        let fixture = RouterFixture(route: .myMacsFirst) { _ in throw LocalRouterUpstreamError.connectTimedOut }
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status == .badGateway)
                let text = String(buffer: response.body)
                #expect(text.contains("darkbloom_unreachable"))
                #expect(text.contains("did not answer the connection in time"))
            }
        }
        // The network is not tried after the coordinator itself could not be reached.
        #expect(fixture.upstream.posts.count == 1)
    }

    @Test func thisMacNeverDialsOutWithoutAnUpstreamRoute() async throws {
        let cases: [(LocalSettings.Route?, String?)] = [(.thisMac, RouterFixture.accountKey), (nil, nil),
                                                        (.myMacs, nil), (.myMacsFirst, nil)]
        for (route, key) in cases {
            let fixture = RouterFixture(route: route, key: key)
            try await fixture.app.test(.router) { client in
                for model in ["absent", "busy", "draining", "here"] {
                    try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                             body: ByteBuffer(string: RouterFixture.chat(model))) { response in
                        #expect(response.headers[LocalRouterPolicy.servedByHeader] == "this-mac")
                        #expect(response.status == (model == "here" ? .ok : model == "absent" ? .notFound
                            : model == "busy" ? .tooManyRequests : .serviceUnavailable))
                    }
                }
                try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                    #expect(response.status == .ok)
                }
            }
            #expect(fixture.factory.count == 0, "route \(String(describing: route)), key \(key != nil)")
            #expect(fixture.upstream.requests.isEmpty)
        }
    }

    @Test func anOversizedBodyIsRefusedBeforeAnything() async throws {
        let fixture = RouterFixture(route: .myMacs)
        let padding = String(repeating: "x", count: 2 * 1024 * 1024)
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/responses", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: #"{"model":"absent","input":"\#(padding)"}"#)) { response in
                #expect(response.status == .contentTooLarge)
                #expect(String(buffer: response.body).contains("2 MiB"))
            }
        }
        #expect(fixture.upstream.requests.isEmpty)
    }

    // MARK: - A `self` hop never comes back to this Mac

    @Test func aSelfHopIsSkippedWhenThisMacIsTheOnlyOneOfTheOwnersMacsServingTheModel() async throws {
        for count in [0, 1, 2] {
            let fixture = RouterFixture(route: .myMacs, takesCoordinatorWork: true) { request in
                if request.method == "GET", request.url.path == "/v1/models/busy" {
                    return count == 0 ? .json(404, #"{"error":{"code":"model_not_found"}}"#)
                        : .json(200, #"{"id":"busy","owned_by":"self","metadata":{"provider_count":\#(count)}}"#)
                }
                return .json(200, #"{"id":"chatcmpl-up"}"#)
            }
            try await fixture.app.test(.router) { client in
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                         body: ByteBuffer(string: RouterFixture.chat("busy"))) { response in
                    if count < 2 {
                        #expect(response.status == .tooManyRequests)
                        #expect(response.headers[LocalRouterPolicy.servedByHeader] == "this-mac")
                        #expect(String(buffer: response.body).contains("this_mac_only"))
                    } else {
                        #expect(response.status == .ok)
                        #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "self")
                    }
                }
            }
            #expect(fixture.upstream.posts.count == (count < 2 ? 0 : 1), "provider_count \(count)")
            let check = try #require(fixture.upstream.requests.first)
            #expect(check.method == "GET" && check.route == "self")
        }
    }

    @Test func myMacsFirstGoesStraightToTheNetworkWhenOnlyThisMacServesTheModel() async throws {
        let fixture = RouterFixture(route: .myMacsFirst, takesCoordinatorWork: true) { request in
            request.method == "GET" ? .json(200, #"{"id":"draining","metadata":{"provider_count":1}}"#)
                : .json(200, #"{"id":"from-prefer"}"#)
        }
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("draining"))) { response in
                #expect(response.status == .ok)
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "prefer")
            }
        }
        #expect(fixture.upstream.posts.map(\.route) == ["prefer"])
    }

    @Test func anAliasOfABuildThisMacServesCountsAsThisMacsModel() async throws {
        let catalog = #"{"models":[{"id":"org/build-4bit","max_context_length":131072,"max_output_length":32768}],"aliases":[{"id":"alias-x","display_name":"Alias X","desired_build":"org/build-4bit"}]}"#
        let fixture = RouterFixture(route: .myMacs, takesCoordinatorWork: true, localModels: ["org/build-4bit"]) { request in
            if request.url.path == "/v1/models/catalog" { return .json(200, catalog) }
            if request.method == "GET" { return .json(200, #"{"id":"alias-x","metadata":{"provider_count":1}}"#) }
            return .json(200, #"{"id":"chatcmpl-up"}"#)
        }
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("alias-x"))) { response in
                #expect(String(buffer: response.body).contains("this_mac_only"))
            }
        }
        #expect(fixture.upstream.posts.isEmpty)
    }

    @Test func aMacThatTakesNoCoordinatorWorkPassesOnWithoutAsking() async throws {
        let fixture = RouterFixture(route: .myMacs, takesCoordinatorWork: false)
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("busy"))) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(fixture.upstream.requests.map(\.method) == ["POST"])
    }

    // MARK: - max_completion_tokens

    @Test(arguments: [false, true])
    func maxCompletionTokensIsReadAsMaxTokensOnThisMac(router: Bool) async throws {
        let fixture = RouterFixture(route: .myMacs, router: router)
        try await fixture.app.test(.router) { client in
            for extra in [#","max_completion_tokens":7"#, #","max_tokens":5,"max_completion_tokens":7"#,
                          #","stop":["max_completion_tokens"]"#] {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                         body: ByteBuffer(string: RouterFixture.chat("here", extra: extra))) { response in
                    #expect(response.status == .ok)
                }
            }
            // Passed on, the request goes as the client wrote it: the coordinator reads all three names.
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent", extra: #","max_completion_tokens":9"#))) { _ in }
        }
        #expect(fixture.engine.requests.filter { $0.model == "here" }.map(\.maxTokens) == [7, 5, nil])
        #expect(fixture.upstream.posts.map(\.bodyText)
            == (router ? [RouterFixture.chat("absent", extra: #","max_completion_tokens":9"#)] : []))
    }

    @Test func maxCompletionTokensDecodesAsMaxTokens() throws {
        func limit(_ json: String) throws -> Int? {
            try JSONDecoder().decode(LocalChatRequest.self, from: Data(json.utf8)).request.maxTokens
        }
        let chat = #"{"model":"m","messages":[{"role":"user","content":"hi"}]"#
        #expect(try limit(chat + #","max_completion_tokens":12}"#) == 12)
        #expect(try limit(chat + #","max_tokens":3,"max_completion_tokens":12}"#) == 3)
        #expect(try limit(chat + #","max_completion_tokens":-1}"#) == -1)
        for ignored in [#""12""#, "1.5", "true", "null"] {
            #expect(try limit(chat + #","max_completion_tokens":\#(ignored)}"#) == nil, "\(ignored)")
        }
        let batch = try JSONDecoder().decode([LocalChatRequest].self, from: Data(
            ("[" + chat + #","max_completion_tokens":4},"# + chat + "}]").utf8))
        #expect(batch.map(\.request.maxTokens) == [4, nil])
    }

    // MARK: - Models

    @Test func theModelListMergesThisMacAndTheRouteWithLimits() async throws {
        let catalog = #"{"models":[{"id":"org/qwen-4bit","max_context_length":131072,"max_output_length":32768},{"id":"here","max_context_length":65536,"max_output_length":8192}],"aliases":[{"id":"qwen","display_name":"Qwen","desired_build":"org/qwen-4bit"}]}"#
        let mine = #"{"object":"list","data":[{"id":"qwen","object":"model","created":1,"owned_by":"self","name":"Qwen","metadata":{"provider_count":1}},{"id":"here","object":"model","owned_by":"self"}]}"#
        let network = #"{"object":"list","data":[{"id":"qwen","object":"model","owned_by":"eigeninference","context_length":131072,"max_output_length":32768},{"id":"big","object":"model","owned_by":"eigeninference","name":"Big","context_length":262144,"max_output_length":65536}]}"#
        let fixture = RouterFixture(route: .myMacsFirst,
                                    localLimits: ["here": LocalModelLimits(contextLength: 40960)]) { request in
            switch (request.url.path, request.route) {
            case ("/v1/models/catalog", _): return .json(200, catalog)
            case ("/v1/models", "self"?): return .json(200, mine)
            case ("/v1/models", nil): return .json(200, network)
            default: return .json(500, "{}")
            }
        }
        let listed: (entries: [LocalRouterModelEntry], text: String) = try await fixture.app.test(.router) { client in
            var last: (entries: [LocalRouterModelEntry], text: String) = ([], "")
            for _ in 0..<3 {
                last = try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.accessControlAllowOrigin] == "*")
                    let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
                    return (list.data, String(buffer: response.body))
                }
            }
            return last
        }
        let entries = listed.entries
        #expect(entries.map(\.id) == ["busy", "cut", "draining", "here", "qwen", "big"])
        #expect(entries.map(\.ownedBy) == ["this-mac", "this-mac", "this-mac", "this-mac", "my-macs", "darkbloom"])
        let here = try #require(entries.first { $0.id == "here" })
        // This Mac's engine first (what it admits now), then the catalog for what it doesn't know.
        #expect(here.contextLength == 40960 && here.maxOutputLength == 8192)
        #expect(listed.text.contains(#""max_model_len":40960"#))
        let qwen = try #require(entries.first { $0.id == "qwen" })
        #expect(qwen.contextLength == 131072 && qwen.maxOutputLength == 32768 && qwen.name == "Qwen")
        let big = try #require(entries.first { $0.id == "big" })
        #expect(big.contextLength == 262144 && big.maxOutputLength == 65536)
        // Cached: three lists, one read of each upstream source.
        #expect(fixture.upstream.requests.count == 3)
        #expect(fixture.upstream.requests.allSatisfy { $0.method == "GET" })
        #expect(fixture.upstream.requests.first { $0.url.path == "/v1/models/catalog" }?.headers["Authorization"] == nil)
    }

    @Test func theModelListServesThisMacsModelsWhenTheCoordinatorIsUnreachable() async throws {
        var timing = LocalRouter.Timing()
        timing.list = .milliseconds(200)
        for script in [{ _ in throw RouterStubUpstream.Unreachable() },
                       { _ in .init(status: 200, hang: true) }] as [@Sendable (LocalRouterUpstreamRequest) throws -> RouterStubUpstream.Answer] {
            let fixture = RouterFixture(route: .myMacs, timing: timing, upstream: script)
            let started = ContinuousClock.now
            try await fixture.app.test(.router) { client in
                for _ in 0..<2 {
                    try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                        #expect(response.status == .ok)
                        let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
                        #expect(list.data.map(\.id) == RouterStubEngine.servedModels)
                        #expect(list.data.allSatisfy { $0.ownedBy == "this-mac" })
                    }
                }
            }
            #expect(ContinuousClock.now - started < .seconds(3))
            // A failed read is remembered: the second list asks nothing.
            #expect(fixture.upstream.requests.count == 2)
        }
    }
}
