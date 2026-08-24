import Foundation
import Testing

@testable import ProviderCore

// A trivial inner responder is not needed: the auth policy is a pure function,
// tested directly. This keeps the security-critical decision covered without
// standing up a Hummingbird stack.

@Test func localAuthOpenWhenNoTokenConfigured() {
    // nil/empty token => no auth (library default / --no-auth).
    #expect(LocalAuthPolicy.authorize(method: .post, path: "/v1/chat/completions", authorizationHeader: nil, token: nil))
    #expect(LocalAuthPolicy.authorize(method: .post, path: "/v1/chat/completions", authorizationHeader: nil, token: ""))
}

@Test func localAuthRequiresBearerTokenForInference() {
    let token = "dk-local-secret"
    // No header → rejected.
    #expect(!LocalAuthPolicy.authorize(method: .post, path: "/v1/chat/completions", authorizationHeader: nil, token: token))
    // Wrong token → rejected.
    #expect(!LocalAuthPolicy.authorize(method: .post, path: "/v1/chat/completions", authorizationHeader: "Bearer nope", token: token))
    // Missing "Bearer " prefix → rejected.
    #expect(!LocalAuthPolicy.authorize(method: .post, path: "/v1/chat/completions", authorizationHeader: token, token: token))
    // Correct token → allowed.
    #expect(LocalAuthPolicy.authorize(method: .post, path: "/v1/chat/completions", authorizationHeader: "Bearer \(token)", token: token))
}

@Test func localAuthExemptsPreflightAndHealth() {
    let token = "dk-local-secret"
    // OPTIONS preflight passes without a token (CORS).
    #expect(LocalAuthPolicy.authorize(method: .options, path: "/v1/chat/completions", authorizationHeader: nil, token: token))
    // Liveness endpoints pass without a token.
    #expect(LocalAuthPolicy.authorize(method: .get, path: "/health", authorizationHeader: nil, token: token))
    #expect(LocalAuthPolicy.authorize(method: .get, path: "/", authorizationHeader: nil, token: token))
    // But a model-listing GET still needs the token (it reveals the catalog).
    #expect(!LocalAuthPolicy.authorize(method: .get, path: "/v1/models", authorizationHeader: nil, token: token))
}

@Test func localAuthExemptsV1HealthAndHead() {
    let token = "dk-local-secret"
    // The upstream router registers /v1/health as a liveness alias too.
    #expect(LocalAuthPolicy.authorize(method: .get, path: "/v1/health", authorizationHeader: nil, token: token))
    #expect(LocalAuthPolicy.authorize(method: .head, path: "/health", authorizationHeader: nil, token: token))
    // A non-liveness HEAD still requires the token.
    #expect(!LocalAuthPolicy.authorize(method: .head, path: "/v1/models", authorizationHeader: nil, token: token))
}

@Test func localAuthConstantTimeEquals() {
    #expect(LocalAuthPolicy.constantTimeEquals("abc", "abc"))
    #expect(!LocalAuthPolicy.constantTimeEquals("abc", "abd"))
    #expect(!LocalAuthPolicy.constantTimeEquals("abc", "abcd"))
    #expect(!LocalAuthPolicy.constantTimeEquals("", "x"))
    #expect(LocalAuthPolicy.constantTimeEquals("", ""))
}

// LocalEndpoint touches the filesystem via the DARKBLOOM_LOCAL_DIR override, so
// these run serialized to avoid racing on the process-global env var.
@Suite(.serialized)
struct LocalEndpointFileTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbloom-local-\(UUID().uuidString)", isDirectory: true)
        setenv("DARKBLOOM_LOCAL_DIR", dir.path, 1)
        defer {
            unsetenv("DARKBLOOM_LOCAL_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    @Test func tokenIsMintedThenReusedWithPrefixAnd0600() throws {
        try withTempDir { _ in
            let first = try LocalEndpoint.loadOrCreateToken()
            #expect(first.hasPrefix(LocalEndpoint.tokenPrefix))
            #expect(first.count > LocalEndpoint.tokenPrefix.count + 20)

            // Reused, not regenerated.
            let second = try LocalEndpoint.loadOrCreateToken()
            #expect(second == first)

            let perms = try FileManager.default.attributesOfItem(atPath: LocalEndpoint.tokenPath().path)[.posixPermissions] as? NSNumber
            #expect(perms?.int16Value == 0o600)
        }
    }

    @Test func discoveryFileRoundTripsAndIsRemovable() throws {
        try withTempDir { _ in
            let identity = ProcessIdentity(pid: 4242, startTimeMicros: 123_456)
            let info = LocalEndpoint.Info(
                host: "127.0.0.1",
                port: 8123,
                apiKey: "dk-local-abc",
                version: "9.9.9",
                pid: identity.pid,
                processIdentity: identity,
                updatedAt: "2026-01-01T00:00:00Z"
            )
            #expect(info.baseURL == "http://127.0.0.1:8123/v1")
            try LocalEndpoint.writeInfo(info)

            let perms = try FileManager.default.attributesOfItem(atPath: LocalEndpoint.infoPath().path)[.posixPermissions] as? NSNumber
            #expect(perms?.int16Value == 0o600)

            let read = LocalEndpoint.readInfo()
            #expect(read == info)

            LocalEndpoint.removeInfo()
            #expect(LocalEndpoint.readInfo() == nil)
        }
    }

    @Test func infoBaseURLRewritesWildcardBindToLoopback() throws {
        // A 0.0.0.0 bind is not dialable; the client URL must be loopback.
        let identity = ProcessIdentity(pid: 1, startTimeMicros: 100)
        let info = LocalEndpoint.Info(
            host: "0.0.0.0", port: 9000, apiKey: "", version: "1",
            pid: identity.pid, processIdentity: identity, updatedAt: "t")
        #expect(info.baseURL == "http://127.0.0.1:9000/v1")
        #expect(info.host == "0.0.0.0")
    }

    @Test func readLiveInfoRequiresExactKernelIdentity() throws {
        try withTempDir { _ in
            let current = try #require(ProcessIdentity.current())

            // Our exact PID + start identity is live.
            let live = LocalEndpoint.Info(
                host: "127.0.0.1", port: 8000, apiKey: "k", version: "1",
                pid: current.pid, processIdentity: current, updatedAt: "t"
            )
            try LocalEndpoint.writeInfo(live)
            #expect(LocalEndpoint.readLiveInfo() != nil)

            // The same live PID with another start identity models PID reuse.
            let reused = LocalEndpoint.Info(
                host: "127.0.0.1", port: 8000, apiKey: "k", version: "1",
                pid: current.pid,
                processIdentity: ProcessIdentity(
                    pid: current.pid,
                    startTimeMicros: current.startTimeMicros + 1
                ),
                updatedAt: "t"
            )
            try LocalEndpoint.writeInfo(reused)
            #expect(LocalEndpoint.readInfo() != nil)
            #expect(LocalEndpoint.readLiveInfo() == nil)

            // Legacy PID-only records decode but cannot authorize disclosure.
            let legacy = LocalEndpoint.Info(
                host: "127.0.0.1", port: 8000, apiKey: "k", version: "1",
                pid: current.pid, updatedAt: "t"
            )
            try LocalEndpoint.writeInfo(legacy)
            #expect(LocalEndpoint.readInfo() != nil)
            #expect(LocalEndpoint.readLiveInfo() == nil)
        }
    }
}
