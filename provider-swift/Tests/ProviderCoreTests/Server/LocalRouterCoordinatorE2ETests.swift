import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import NIOFoundationCompat
import Testing
@testable import ProviderCore

/// The router against a real coordinator on loopback: the V0 harness (darkbloom-platform `90ee29fc0d` in development
/// mode, memory store, seeded through its own routes, one stub provider for the owner's other Mac). Opt-in:
/// `DARKBLOOM_ROUTER_E2E_BASE=http://127.0.0.1:<port>` and `DARKBLOOM_ROUTER_E2E_KEYS=<dir>` holding the seeded
/// `owner-normal`, `consumer` and `owner3` (zero balance, its Mac offline) `.key.secret` files. This Mac is the stub
/// engine; the coordinator, its `/v1/models` views and the upstream client are real.
@Suite("Local router against the V0 coordinator", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_ROUTER_E2E_BASE"] != nil))
struct LocalRouterCoordinatorE2ETests {
    static let model = "v0/stub-small-model"

    static func key(_ name: String) throws -> String {
        let directory = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_ROUTER_E2E_KEYS"])
        return try String(contentsOfFile: directory + "/\(name).key.secret", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func app(key: String, route: LocalSettings.Route, takesCoordinatorWork: Bool = false,
                    localModels: [String] = RouterStubEngine.servedModels, log: RouterLogLines = .init())
        throws -> LocalInferenceApplication {
        let raw = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_ROUTER_E2E_BASE"])
        let base = try #require(URL(string: raw))
        let engine = RouterStubEngine()
        let router = LocalRouterConfig(
            settings: LocalSettings(route: route), upstreamBaseURL: base, takesCoordinatorWork: takesCoordinatorWork,
            accountKeys: InMemoryLocalRouterAccountKeyStore(key), log: { log.append($0) })
        return makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: RouterFixture.localKey, router: router),
            defaultMaxTokens: 32,
            acquire: { throw MultiModelBatchSchedulerEngineError.modelNotLoaded($0) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { localModels }, mtpSlots: { [] },
            managedSuperEngine: { _, _, _ in engine })
    }

    static let chat = #"{"model":"\#(model)","stream":true,"max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#

    @Test func theOwnersOtherMacAnswersThroughSelfAndTheListCarriesItsLimits() async throws {
        let owner = try Self.key("owner-normal")
        let log = RouterLogLines()
        try await Self.app(key: owner, route: .myMacs, log: log).test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
                let remote = try #require(list.data.first { $0.id == Self.model })
                print("e2e /v1/models \(Self.model): owned_by \(remote.ownedBy), context \(String(describing: remote.contextLength)), output \(String(describing: remote.maxOutputLength))")
                #expect(remote.ownedBy == "my-macs")
                #expect(remote.contextLength == 32768 && remote.maxOutputLength == 8192)
                #expect(list.data.filter { $0.ownedBy == "this-mac" }.map(\.id) == RouterStubEngine.servedModels)
            }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: Self.chat)) { response in
                let text = String(buffer: response.body)
                print("e2e self chat: \(response.status.code) served-by \(response.headers[LocalRouterPolicy.servedByHeader] ?? "-") route-used \(response.headers[LocalRouterPolicy.routeUsedHeader] ?? "-") sse-events \(text.components(separatedBy: "data:").count - 1)")
                #expect(response.status == .ok)
                #expect(response.headers[LocalRouterPolicy.servedByHeader] == "darkbloom")
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "self")
                #expect(text.contains("data:") && !text.contains(owner))
            }
        }
        #expect(!log.lines.joined().contains(owner))
    }

    @Test func aConsumerWithoutAMacGetsTheCoordinatorsRefusalVerbatim() async throws {
        try await Self.app(key: try Self.key("consumer"), route: .myMacs).test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: Self.chat)) { response in
                let text = String(buffer: response.body)
                print("e2e consumer self: \(response.status.code) \(text.prefix(160))")
                #expect(response.status.code == 409)
                #expect(text.contains("no_linked_machine"))
            }
        }
    }

    @Test func aZeroBalanceOwnerWithItsMacOfflineHearsTheNetworkFallbackNeedsABalance() async throws {
        try await Self.app(key: try Self.key("owner3"), route: .myMacsFirst).test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: Self.chat)) { response in
                let text = String(buffer: response.body)
                print("e2e owner3 my-macs-first: \(response.status.code) route-used \(response.headers[LocalRouterPolicy.routeUsedHeader] ?? "-") \(text.prefix(220))")
                #expect(response.status.code == 402)
                #expect(response.headers[LocalRouterPolicy.routeUsedHeader] == "prefer")
                #expect(text.contains("No balance for the network fallback") && text.contains("insufficient_quota"))
            }
        }
    }

    @Test func aSelfHopThatCouldOnlyReachThisMacIsNotSent() async throws {
        let owner = try Self.key("owner-normal")
        // This Mac lists the model the owner's one other Mac serves; the coordinator counts one Mac serving it.
        for takesWork in [true, false] {
            try await Self.app(key: owner, route: .myMacs, takesCoordinatorWork: takesWork,
                               localModels: [Self.model]).test(.router) { client in
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                         body: ByteBuffer(string: Self.chat)) { response in
                    let text = String(buffer: response.body)
                    print("e2e takesCoordinatorWork \(takesWork): \(response.status.code) \(text.contains("this_mac_only") ? "this_mac_only" : "passed on")")
                    #expect(text.contains("this_mac_only") == takesWork)
                    #expect((response.status == .ok) == !takesWork)
                }
            }
        }
    }
}
