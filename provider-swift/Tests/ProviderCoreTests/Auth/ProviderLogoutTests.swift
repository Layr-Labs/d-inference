import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import Testing
@testable import ProviderCore

@Suite struct ProviderLogoutTests {
    private enum Failure: Error { case stop, delete }

    @Test(arguments: [true, false]) func stopsBeforeRevokingAndDeleting(remoteConfirmed: Bool) async throws {
        var calls: [String] = []
        var saved: String? = "synthetic-provider-token"
        let outcome = try await ProviderLogout.perform(
            stopProvider: { calls.append("stop-and-disable") },
            loadToken: { calls.append("load"); return saved },
            revokeToken: { token in
                calls.append("revoke")
                #expect(token == saved)
                return remoteConfirmed
            }, deleteToken: { calls.append("delete"); saved = nil })
        #expect(calls == ["stop-and-disable", "load", "revoke", "delete"])
        #expect(saved == nil)
        #expect(outcome == (remoteConfirmed ? .revoked : .remoteUnconfirmed))
    }

    @Test func stopFailurePreservesCredentialForRetry() async {
        var calls: [String] = []
        var saved: String? = "synthetic-provider-token"
        await #expect(throws: Failure.stop) {
            _ = try await ProviderLogout.perform(
                stopProvider: { calls.append("stop"); throw Failure.stop },
                loadToken: { calls.append("load"); return saved },
                revokeToken: { _ in calls.append("revoke"); return true },
                deleteToken: { calls.append("delete"); saved = nil })
        }
        #expect(calls == ["stop"])
        #expect(saved == "synthetic-provider-token")
    }

    @Test func missingCredentialStillStopsAndIsIdempotent() async throws {
        var calls: [String] = []
        for _ in 0..<2 {
            let outcome = try await ProviderLogout.perform(
                stopProvider: { calls.append("stop") }, loadToken: { nil },
                revokeToken: { _ in Issue.record("no credential to revoke"); return true },
                deleteToken: { calls.append("delete") })
            #expect(outcome == .noCredential)
        }
        #expect(calls == ["stop", "delete", "stop", "delete"])
    }

    @Test func localDeletionFailureCannotReturnSuccess() async {
        await #expect(throws: Failure.delete) {
            _ = try await ProviderLogout.perform(stopProvider: {}, loadToken: { "synthetic-provider-token" },
                revokeToken: { _ in true }, deleteToken: { throw Failure.delete })
        }
    }

    @Test func canonicalCredentialIsPreservedOnStopFailureAndRemovedOffline() async {
        await #expect(processExitsWith: .success) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("logout-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("auth_token")
            setenv("DARKBLOOM_AUTH_TOKEN_PATH", path.path, 1)
            try AuthTokenStore.save("synthetic-provider-token")
            struct StopFailed: Error {}
            do {
                _ = try await ProviderLogout.perform(stopProvider: { throw StopFailed() },
                    revokeToken: { _ in Issue.record("must not revoke after failed stop"); return true })
                Issue.record("Expected stop failure")
            } catch is StopFailed {}
            #expect(AuthTokenStore.load() == "synthetic-provider-token")
            let offline = try await ProviderLogout.perform(stopProvider: {}, revokeToken: { _ in false })
            #expect(offline == .remoteUnconfirmed)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            let repeated = try await ProviderLogout.perform(stopProvider: {}, revokeToken: { _ in
                Issue.record("missing token cannot revoke another device"); return true
            })
            #expect(repeated == .noCredential)
        }
    }

    @Test func issuerMetadataIsBoundToSavedTokenAndRemovedWithIt() async {
        await #expect(processExitsWith: .success) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("issuer-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("auth_token")
            setenv("DARKBLOOM_AUTH_TOKEN_PATH", path.path, 1)
            try AuthTokenStore.save("first-token", coordinatorURL: "https://issuer.example/v1/device/token")
            #expect(AuthTokenStore.load() == "first-token")
            #expect(AuthTokenStore.issuer(for: "first-token") == "https://issuer.example/v1/device/token")
            #expect(AuthTokenStore.issuer(for: "other-token") == nil)
            let metadata = path.appendingPathExtension("issuer.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: metadata.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let oldMetadata = try Data(contentsOf: metadata)
            try AuthTokenStore.save("second-token")
            #expect(AuthTokenStore.issuer(for: "second-token") == nil)
            try oldMetadata.write(to: metadata)
            #expect(AuthTokenStore.issuer(for: "second-token") == nil)
            try AuthTokenStore.delete()
            #expect(AuthTokenStore.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: metadata.path))
        }
    }

    @Test func failedIssuerSaveRollsBackTokenAndAllowsRetry() async {
        await #expect(processExitsWith: .success) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("issuer-failure-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("auth_token")
            let issuer = path.appendingPathExtension("issuer.json")
            setenv("DARKBLOOM_AUTH_TOKEN_PATH", path.path, 1)
            try FileManager.default.createDirectory(at: issuer, withIntermediateDirectories: true)
            let occupant = issuer.appendingPathComponent("preserve")
            try Data("existing path occupant".utf8).write(to: occupant)

            #expect(throws: (any Error).self) {
                try AuthTokenStore.save("failed-token", coordinatorURL: "https://issuer.example")
            }
            #expect(AuthTokenStore.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(try Data(contentsOf: occupant) == Data("existing path occupant".utf8))

            try FileManager.default.removeItem(at: issuer)
            try AuthTokenStore.save("retry-token", coordinatorURL: "https://issuer.example")
            #expect(AuthTokenStore.load() == "retry-token")
            #expect(AuthTokenStore.issuer(for: "retry-token") == "https://issuer.example")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 202, 204, 301, 302, 307, 308, 401, 404, 500])
    func localHTTPRequiresExact204AndNeverFollowsRedirect(status: Int) async throws {
        let capture = LogoutHTTPCapture()
        let router = Router()
        router.post("/v1/device/revoke") { request, _ -> Response in
            await capture.record(request.headers[.authorization])
            return Response(status: .init(code: status), headers: [.location: "/redirect-target"])
        }
        router.get("/redirect-target") { _, _ -> Response in
            await capture.redirected()
            return Response(status: .noContent)
        }
        router.post("/redirect-target") { _, _ -> Response in
            await capture.redirected()
            return Response(status: .noContent)
        }
        let (ports, ready) = AsyncStream.makeStream(of: Int.self)
        var logger = Logger(label: "LogoutHTTPFixture")
        logger.logLevel = .critical
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in ready.yield(channel.localAddress?.port ?? 0); ready.finish() }, logger: logger)
        let server = Task {
            defer { ready.finish() }
            try await app.runService(gracefulShutdownSignals: [])
        }
        defer { server.cancel() }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())
        try #require(port > 0)
        let confirmed = await ProviderLogout.revokeToken("synthetic-provider-token",
            coordinatorURL: "ws://127.0.0.1:\(port)/ws/provider?ignored=1#fragment")
        #expect(confirmed == (status == 204))
        #expect(await capture.authorizations == ["Bearer synthetic-provider-token"])
        #expect(await capture.redirects == 0)
        server.cancel()
        _ = try? await server.value
    }

    @Test func offlineResponseIsBoundedAndNeverConfirmed() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogoutOfflineProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let confirmed = await ProviderLogout.revokeToken("synthetic-provider-token",
            coordinatorURL: "http://127.0.0.1:1", session: session)
        #expect(!confirmed)
    }

    @Test func revocationPreservesAuthorityWhenReplacingWebSocketPath() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogoutAuthorityProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for (coordinator, expected) in [
            ("wss://api.example/ws/provider.attacker.test", "https://api.example/v1/device/revoke"),
            ("wss://api.example:8443/ws/provider.attacker.test?x=1#fragment", "https://api.example:8443/v1/device/revoke"),
            ("ws://127.0.0.1:12345/ws/provider.attacker.test", "http://127.0.0.1:12345/v1/device/revoke"),
            ("https://api.example/nested/path?x=1", "https://api.example/v1/device/revoke"),
            ("WSS://api.example/ws/provider", "https://api.example/v1/device/revoke"),
        ] {
            // Encode the expected URL in this synthetic token so the URLProtocol
            // can check each request without shared mutable capture state.
            #expect(await ProviderLogout.revokeToken(expected, coordinatorURL: coordinator, session: session))
        }
    }

    @Test(arguments: ["file:///tmp/no-coordinator", "http://user:password@127.0.0.1:1", "not a URL"])
    func invalidCoordinatorCannotConfirmRevocation(url: String) async {
        #expect(await !ProviderLogout.revokeToken("synthetic-provider-token", coordinatorURL: url))
    }
}

private final class LogoutAuthorityProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(url.absoluteString)")
        #expect(url.path == "/v1/device/revoke")
        #expect(url.query == nil && url.fragment == nil)
        let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor LogoutHTTPCapture {
    var authorizations: [String?] = []
    var redirects = 0
    func record(_ authorization: String?) { authorizations.append(authorization) }
    func redirected() { redirects += 1 }
}

private final class LogoutOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.absoluteString == "http://127.0.0.1:1/v1/device/revoke")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 10)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-provider-token")
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}
