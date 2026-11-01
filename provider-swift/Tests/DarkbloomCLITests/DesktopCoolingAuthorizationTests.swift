import Foundation
import Testing
@testable import darkbloom

struct DesktopCoolingAuthorizationTests {
  let firmware = "execution error: fan ownership recovery failed: restoreMode fan 0: SMC firmware rejected writeBytes for F0Md (0x82); clearFtst global: Ftst remained 1 (1)"
  @Test func retriesTransientFirmwareRestorationButPreservesTheCommand() async throws {
    let runner = Runner([(1, firmware), (0, "Fan enabled")])
    let value = try await DesktopCoolingAuthorization.perform(script: "verified-command",
      run: { await runner.run($0) }, pause: {})
    #expect(value == "Fan enabled")
    #expect(await runner.scripts == ["verified-command", "verified-command"])
  }
  @Test func permanentFirmwareFailureRemainsVisibleAfterThreeAttempts() async throws {
    let runner = Runner(Array(repeating: (1, firmware), count: 3))
    do {
      _ = try await DesktopCoolingAuthorization.perform(script: "verified-command",
        run: { await runner.run($0) }, pause: {})
      Issue.record("Persistent restoration failure must not succeed")
    } catch let error as DesktopCoolingAuthorization.Failure {
      #expect(!error.cancelled)
      #expect(error.description.contains("F0Md (0x82)"))
      #expect(!error.description.contains("authorization cancelled"))
    }
    #expect(await runner.scripts.count == 3)
  }
  @Test func authorizationCancellationAndOtherFailuresAreNotRetried() async throws {
    for message in ["User canceled. (-128)", "signed helper missing", "foreign manual control"] {
      let runner = Runner([(1, message)])
      do {
        _ = try await DesktopCoolingAuthorization.perform(script: "verified-command",
          run: { await runner.run($0) }, pause: {})
        Issue.record("Failed command must remain failed")
      } catch let error as DesktopCoolingAuthorization.Failure {
        #expect(error.cancelled == message.contains("(-128)"))
      }
      #expect(await runner.scripts.count == 1)
    }
  }
}
private actor Runner {
  var results: [(Int32, String)]
  var scripts: [String] = []
  init(_ results: [(Int32, String)]) { self.results = results }
  func run(_ script: String) -> (Int32, String) {
    scripts.append(script)
    return results.removeFirst()
  }
}
