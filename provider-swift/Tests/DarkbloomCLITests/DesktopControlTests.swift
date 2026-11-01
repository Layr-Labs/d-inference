import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import darkbloom

struct DesktopControlTests {
  @Test func workerDrainsOutputBeforeCompletingAndBoundsTheTail() async throws {
    let worker = DesktopWorker(executable: URL(fileURLWithPath: "/usr/bin/printf"))
    let (status, output) = try await worker.run(["%50000s%s", "x", "final-marker"])
    #expect(status == 0)
    #expect(output.utf8.count == 32_768)
    #expect(output.hasSuffix("final-marker"))
  }

  @Test func cancelledWorkerNeverStartsTheChild() async throws {
    let worker = DesktopWorker(executable: URL(fileURLWithPath: "/usr/bin/true"))
    worker.cancel()
    await #expect(throws: CancellationError.self) { try await worker.run([]) }
  }
  @Test func authRejectsBrowserAndForeignHost() {
    let token = String(repeating: "a", count: 44)
    #expect(
      DesktopHTTP.authorized(
        header: "Bearer \(token)", token: token, origin: nil, host: "127.0.0.1:4321"))
    #expect(
      !DesktopHTTP.authorized(
        header: "Bearer \(token)", token: token, origin: "https://example.com",
        host: "127.0.0.1:4321"))
    #expect(
      !DesktopHTTP.authorized(
        header: "Bearer \(token)", token: token, origin: nil, host: "attacker.example"))
    #expect(
      !DesktopHTTP.authorized(header: "Bearer wrong", token: token, origin: nil, host: "127.0.0.1"))
    #expect(!DesktopHTTP.authorized(header: nil, token: token, origin: nil, host: "127.0.0.1"))
  }

  @Test(arguments: [
    "../escape", "/tmp/model", "--force", "model;touch /tmp/x", "model\n--force", "",
  ])
  func modelArgumentsCannotBecomeOptionsOrPaths(value: String) {
    #expect(throws: (any Error).self) { try DesktopAction.validateModel(value) }
  }

  @Test func acceptsRegistryIdentifiers() throws {
    try DesktopAction.validateModel("mlx-community/gpt-oss-20b-MXFP4-Q8")
  }

  @Test func rejectsInvalidActionsBeforeStartingAProcess() throws {
    let data = Data(
      """
      {"id":"\(UUID().uuidString)","action":"start","models":["--force"]}
      """.utf8)
    let action = try JSONDecoder().decode(DesktopAction.self, from: data)
    #expect(throws: (any Error).self) { try action.validate() }
  }

  @Test func missingCredentialsCannotReachControlHandlers() async throws {
    let app = Application(
      responder: DesktopHTTP(
        backend: DesktopBackend(configPath: "/nonexistent-desktop-test-config"),
        token: "fixture-token"))
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/control/v1/actions", method: .post, body: ByteBuffer(string: "{}")
      ) { response in
        #expect(response.status == .unauthorized)
        #expect(response.headers[.accessControlAllowOrigin] == nil)
      }
    }
  }
}
