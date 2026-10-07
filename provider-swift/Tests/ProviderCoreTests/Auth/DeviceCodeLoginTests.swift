import Foundation
import Testing
@testable import ProviderCore

// Each URL selects its response, so concurrent tests need no global mutable fixture.
private final class DeviceLoginProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "device-login.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let path = request.url!.path
    let scoped = path.hasPrefix("/scoped") || path.hasPrefix("/wrong")
    let body: String
    if path.hasSuffix("/code") {
      body = """
        {"device_code":"\(scoped ? "desktop-account-code" : "legacy-code")","user_code":"TEST-CODE","verification_uri":"https://device-login.test/link","expires_in":15,"interval":1\(scoped ? ",\"purpose\":\"desktop_account\"" : "")}
        """
    } else {
      let valid = !path.hasPrefix("/wrong")
      body = """
        {"status":"authorized","token":"\(scoped && valid ? "darkbloom-at-test" : "eigeninference-pt-test")"\(scoped ? ",\"purpose\":\"desktop_account\"" : "")}
        """
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

private final class LoginCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [String] = []
  func opened(_ url: String) { lock.withLock { urls.append(url) } }
  var count: Int { lock.withLock { urls.count } }
}

struct DeviceCodeLoginTests {
  private func client(_ calls: LoginCalls) -> DeviceLoginClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DeviceLoginProtocol.self]
    return DeviceLoginClient(session: URLSession(configuration: config), openBrowser: calls.opened,
      saveProviderToken: { _ in throw DeviceAuthError.invalidResponse("Account login attempted to replace provider credentials") })
  }

  @Test func olderCoordinatorUsesExistingDeviceEndpointsWithoutChangingProviderCredentials() async throws {
    let calls = LoginCalls()
    let token = try await client(calls).login(coordinatorURL: "https://device-login.test/legacy",
      onDisplayCode: { code, _, _ in #expect(code == "TEST-CODE") }, purpose: "desktop_account", allowLegacyAccountFlow: true)
    #expect(token == "eigeninference-pt-test")
    #expect(calls.count == 1)
  }

  @Test func desktopDisplaysCodeAndPollsWithoutLaunchingBrowser() async throws {
    let calls = LoginCalls()
    let token = try await client(calls).login(coordinatorURL: "https://device-login.test/scoped",
      onDisplayCode: { code, url, _ in
        #expect(code == "TEST-CODE")
        #expect(url == "https://device-login.test/link")
      }, purpose: "desktop_account", allowLegacyAccountFlow: true, automaticallyOpenBrowser: false)
    #expect(token == "darkbloom-at-test")
    #expect(calls.count == 0)
  }

  @Test func scopedCoordinatorStillUsesTheScopedAccountSession() async throws {
    let calls = LoginCalls()
    let token = try await client(calls).login(coordinatorURL: "https://device-login.test/scoped",
      onDisplayCode: { _, _, _ in }, purpose: "desktop_account", allowLegacyAccountFlow: true)
    #expect(token == "darkbloom-at-test")
    #expect(calls.count == 1)
  }

  @Test func scopeMismatchNeverDowngradesAnAcknowledgedAccountGrant() async {
    let calls = LoginCalls()
    await #expect(throws: DeviceAuthError.self) {
      try await client(calls).login(coordinatorURL: "https://device-login.test/wrong",
        onDisplayCode: { _, _, _ in }, purpose: "desktop_account", allowLegacyAccountFlow: true)
    }
  }

  @Test func legacyCompatibilityMustBeExplicitlyEnabled() async {
    let calls = LoginCalls()
    await #expect(throws: DeviceAuthError.self) {
      try await client(calls).login(coordinatorURL: "https://device-login.test/legacy",
        onDisplayCode: { _, _, _ in }, purpose: "desktop_account")
    }
    #expect(calls.count == 0)
  }
}
