import Foundation
import Testing
@testable import ProviderCore

@Test func coordinatorIssuerCanonicalizesWebSocketAndHTTPURLs() throws {
    #expect(
        try canonicalCoordinatorIssuer(
            "wss://API.Darkbloom.dev/ws/provider?ignored=1#fragment"
        ) == "https://api.darkbloom.dev"
    )
    #expect(
        try canonicalCoordinatorIssuer("ws://127.0.0.1:8080/custom/path/")
            == "http://127.0.0.1:8080"
    )
    #expect(throws: ProviderCredentialStoreError.invalidCoordinatorURL) {
        _ = try canonicalCoordinatorIssuer("file:///tmp/coordinator")
    }
}

@Test func authTokenLoadMigratesLegacyTokenToCanonicalPath() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("darkbloom-device-auth-")
        .appendingPathComponent(UUID().uuidString)
    let canonical = tempDir.appendingPathComponent("darkbloom").appendingPathComponent("auth_token")
    let legacy = tempDir.appendingPathComponent("eigeninference").appendingPathComponent("auth_token")
    try FileManager.default.createDirectory(
        at: legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "legacy-token\n".write(to: legacy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let token = AuthTokenStore.load(canonicalPath: canonical, legacyPaths: [legacy])

    #expect(token == "legacy-token")
    #expect(try String(contentsOf: canonical, encoding: .utf8) == "legacy-token")
}

@Test func authTokenLoadPrefersCanonicalTokenOverLegacyToken() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("darkbloom-device-auth-")
        .appendingPathComponent(UUID().uuidString)
    let canonical = tempDir.appendingPathComponent("darkbloom").appendingPathComponent("auth_token")
    let legacy = tempDir.appendingPathComponent("eigeninference").appendingPathComponent("auth_token")
    try FileManager.default.createDirectory(
        at: canonical.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "canonical-token\n".write(to: canonical, atomically: true, encoding: .utf8)
    try "legacy-token\n".write(to: legacy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let token = AuthTokenStore.load(canonicalPath: canonical, legacyPaths: [legacy])

    #expect(token == "canonical-token")
}

@Test func authTokenDeleteRemovesCanonicalAndLegacyTokens() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("darkbloom-device-auth-")
        .appendingPathComponent(UUID().uuidString)
    let canonical = tempDir.appendingPathComponent("darkbloom").appendingPathComponent("auth_token")
    let legacy = tempDir.appendingPathComponent("eigeninference").appendingPathComponent("auth_token")
    try FileManager.default.createDirectory(
        at: canonical.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "canonical-token\n".write(to: canonical, atomically: true, encoding: .utf8)
    try "legacy-token\n".write(to: legacy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try AuthTokenStore.delete(canonicalPath: canonical, legacyPaths: [legacy])

    #expect(!FileManager.default.fileExists(atPath: canonical.path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
}

@Test func providerTokenRevokerSendsAuthenticatedDelete() async throws {
    let recorder = TokenRevokeRequestRecorder(status: 204)
    let revoker = ProviderTokenRevoker { request in
        try await recorder.send(request)
    }

    try await revoker.revoke(
        coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
        token: "provider-secret"
    )

    let request = try #require(await recorder.request)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.absoluteString == "https://api.darkbloom.dev/v1/device/token")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer provider-secret")
}

@Test func providerTokenRevokerRejectsNonSuccess() async {
    let recorder = TokenRevokeRequestRecorder(status: 503)
    let revoker = ProviderTokenRevoker { request in
        try await recorder.send(request)
    }

    await #expect(throws: ProviderTokenRevokeError.rejected(status: 503)) {
        try await revoker.revoke(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            token: "provider-secret"
        )
    }
}

private actor TokenRevokeRequestRecorder {
    private(set) var request: URLRequest?
    private let status: Int

    init(status: Int) {
        self.status = status
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        self.request = request
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (Data(), response)
    }
}
