import Foundation
import Testing

@testable import darkbloom

/// `desktop ensure` decisions and `stop --uninstall` cleanup for the desktop
/// API LaunchAgent. Nothing here calls launchctl.
struct DesktopServiceTests {
  static let expected = "1.2.3"

  struct Case: Sendable, CustomTestStringConvertible {
    let loaded: Bool
    let plistCurrent: Bool
    let observation: DesktopService.Observation
    let restarted: Bool
    let step: DesktopService.Step
    var testDescription: String {
      "loaded=\(loaded) current=\(plistCurrent) \(observation) restarted=\(restarted)"
    }
  }

  static func answered(_ version: String, running: Bool = false) -> DesktopService.Observation {
    .answered(version: version, runningOperation: running)
  }

  static let cases: [Case] = [
    // First pass.
    Case(loaded: false, plistCurrent: false, observation: .noAnswer, restarted: false, step: .install),
    Case(loaded: false, plistCurrent: true, observation: .noAnswer, restarted: false, step: .install),
    Case(loaded: true, plistCurrent: false, observation: .noAnswer, restarted: false, step: .reinstall),
    Case(
      loaded: true, plistCurrent: false, observation: answered(expected), restarted: false,
      step: .reinstall),
    Case(
      loaded: true, plistCurrent: false, observation: answered("1.0.0"), restarted: false,
      step: .reinstall),
    Case(
      loaded: true, plistCurrent: true, observation: answered(expected), restarted: false,
      step: .ready),
    Case(
      loaded: true, plistCurrent: true, observation: answered("1.0.0"), restarted: false,
      step: .restart),
    Case(loaded: true, plistCurrent: true, observation: .noAnswer, restarted: false, step: .restart),
    // A running operation is never interrupted; the API restarts itself later.
    Case(
      loaded: true, plistCurrent: true, observation: answered("1.0.0", running: true),
      restarted: false, step: .deferred),
    Case(
      loaded: true, plistCurrent: false, observation: answered("1.0.0", running: true),
      restarted: false, step: .deferred),
    Case(
      loaded: true, plistCurrent: false, observation: answered(expected, running: true),
      restarted: false, step: .deferred),
    Case(
      loaded: true, plistCurrent: true, observation: answered(expected, running: true),
      restarted: false, step: .ready),
    // An API that answers with an error is not restarted onto the same plist.
    Case(
      loaded: true, plistCurrent: true, observation: .failed(status: 500), restarted: false,
      step: .fail("Desktop API answered HTTP 500. Check the provider configuration.")),
    Case(
      loaded: true, plistCurrent: false, observation: .failed(status: 500), restarted: false,
      step: .reinstall),
    // After the single allowed restart.
    Case(
      loaded: true, plistCurrent: true, observation: answered(expected), restarted: true,
      step: .ready),
    Case(
      loaded: true, plistCurrent: true, observation: answered("1.0.0"), restarted: true,
      step: .fail("Desktop API still reports version 1.0.0 after a restart; expected 1.2.3")),
    Case(
      loaded: true, plistCurrent: true, observation: .noAnswer, restarted: true,
      step: .fail("Desktop API did not become ready")),
    Case(
      loaded: true, plistCurrent: true, observation: .failed(status: 500), restarted: true,
      step: .fail("Desktop API answered HTTP 500. Check the provider configuration.")),
    Case(
      loaded: false, plistCurrent: true, observation: .noAnswer, restarted: true,
      step: .fail("The desktop API LaunchAgent did not load")),
  ]

  @Test(arguments: cases)
  func ensureRestartsAtMostOnceAndNeverDuringAnOperation(_ item: Case) {
    #expect(
      DesktopService.nextStep(
        loaded: item.loaded, plistCurrent: item.plistCurrent, observation: item.observation,
        expectedVersion: Self.expected, restarted: item.restarted) == item.step)
  }

  @Test func configPathIsAbsoluteBeforeItReachesThePlist() {
    #expect(DesktopService.absoluteConfigPath(nil) == nil)
    #expect(
      DesktopService.absoluteConfigPath("conf/provider.toml", relativeTo: "/tmp/work")
        == "/tmp/work/conf/provider.toml")
    #expect(
      DesktopService.absoluteConfigPath("../provider.toml", relativeTo: "/tmp/work")
        == "/tmp/provider.toml")
    #expect(
      DesktopService.absoluteConfigPath("/etc/darkbloom.toml", relativeTo: "/tmp/work")
        == "/etc/darkbloom.toml")
    #expect(
      DesktopService.absoluteConfigPath("~/provider.toml", relativeTo: "/tmp/work")
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("provider.toml")
        .path)
  }

  @Test func installedPlistIsCurrentOnlyWhenIdentical() throws {
    let logs = URL(fileURLWithPath: "/tmp/desktop-service-fixture")
    let desired = DesktopService.plist(
      executable: "/opt/darkbloom/bin/darkbloom", configPath: "/tmp/provider.toml",
      logDirectory: logs)
    let encode = { (plist: [String: Any]) in
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    #expect(DesktopService.isCurrent(installed: try encode(desired), desired: desired))
    #expect(!DesktopService.isCurrent(installed: nil, desired: desired))
    #expect(!DesktopService.isCurrent(installed: Data("not a plist".utf8), desired: desired))

    let otherConfig = DesktopService.plist(
      executable: "/opt/darkbloom/bin/darkbloom", configPath: nil, logDirectory: logs)
    #expect(!DesktopService.isCurrent(installed: try encode(otherConfig), desired: desired))
    let otherBinary = DesktopService.plist(
      executable: "/Applications/Other/darkbloom", configPath: "/tmp/provider.toml",
      logDirectory: logs)
    #expect(!DesktopService.isCurrent(installed: try encode(otherBinary), desired: desired))
    // A plist from an older release (no ExitTimeOut) is refreshed too.
    var older = desired
    older["ExitTimeOut"] = nil
    #expect(!DesktopService.isCurrent(installed: try encode(older), desired: desired))
  }

  @Test func plistServesTheDesktopAPIUnderOneLabel() throws {
    let home = URL(fileURLWithPath: "/Users/fixture")
    #expect(
      DesktopService.plistPath(home: home).path
        == "/Users/fixture/Library/LaunchAgents/io.darkbloom.desktop-api.plist")
    let plist = DesktopService.plist(
      executable: "/bin/darkbloom", configPath: "/tmp/p.toml",
      logDirectory: URL(fileURLWithPath: "/tmp/d"))
    #expect(plist["Label"] as? String == DesktopService.label)
    #expect(
      plist["ProgramArguments"] as? [String]
        == ["/bin/darkbloom", "desktop", "serve", "--config", "/tmp/p.toml"])
  }

  @Test func uninstallUnloadsThenRemovesThePlist() throws {
    let plist = try Self.temporaryPlist()
    var unloaded = false
    try DesktopService.uninstall(plist: plist) {
      #expect(FileManager.default.fileExists(atPath: plist.path))
      unloaded = true
    }
    #expect(unloaded)
    #expect(!FileManager.default.fileExists(atPath: plist.path))
    // Idempotent once nothing is installed.
    try DesktopService.uninstall(plist: plist) {}
  }

  @Test func uninstallRemovesThePlistEvenWhenUnloadFails() throws {
    struct BootoutFailed: Error {}
    let plist = try Self.temporaryPlist()
    #expect(throws: BootoutFailed.self) {
      try DesktopService.uninstall(plist: plist) { throw BootoutFailed() }
    }
    #expect(!FileManager.default.fileExists(atPath: plist.path))
  }

  static func temporaryPlist() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-service-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let plist = directory.appendingPathComponent("\(DesktopService.label).plist")
    try Data("<plist/>".utf8).write(to: plist)
    return plist
  }
}
