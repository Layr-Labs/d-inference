import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// A local desktop preview bundles this API but drives the installed, released runtime, which
/// can be older: it has its own version and may not have the `desktop` subcommands.
struct DesktopRuntimeProfileTests {
  /// What a released runtime without the `desktop` group prints for `desktop --help`: its
  /// top-level help, with exit status 0.
  static let releasedTopLevelHelp = """
    OVERVIEW: Swift-native provider CLI for Darkbloom.

    USAGE: darkbloom <subcommand>

    OPTIONS:
      --version               Show the version.
      -h, --help              Show help information.

    SUBCOMMANDS:
      start                   Start the provider as a background service.
      stop                    Drain accepted requests, then persistently stop the
                              provider service.
      update                  Update the provider.
    """

  static let desktopHelp = """
    OVERVIEW: Serve the authenticated desktop control API.

    USAGE: darkbloom desktop <subcommand>

    SUBCOMMANDS:
      serve                   Serve the desktop API.
      configure-cooling       Configure provider cooling.
      start-local             Start serving locally.
    """

  @Test func readsTheRuntimeVersionLine() {
    #expect(DesktopRuntimeProfile.parseVersion("0.9.20\n") == "0.9.20")
    #expect(DesktopRuntimeProfile.parseVersion("1.2.3-beta.1") == "1.2.3-beta.1")
    #expect(DesktopRuntimeProfile.parseVersion("Error: Unknown option '--version'") == nil)
    #expect(DesktopRuntimeProfile.parseVersion("Warning: diagnostic\n0.9.20\n") == nil)
    #expect(DesktopRuntimeProfile.parseVersion("0.9.20\nAnother log line\n") == nil)
    #expect(DesktopRuntimeProfile.parseVersion("") == nil)
  }

  @Test func onlyADesktopUsageLineListsDesktopCommands() {
    #expect(DesktopRuntimeProfile.parseDesktopCommands(Self.releasedTopLevelHelp).isEmpty)
    #expect(
      DesktopRuntimeProfile.parseDesktopCommands(Self.desktopHelp)
        == ["serve", "configure-cooling", "start-local"])
  }

  @Test func thisBuildOffersItsOwnDesktopCommands() {
    #expect(DesktopRuntimeProfile.current.version == ProviderCore.version)
    for command in ["configure-cooling", "start-local", "stop-local", "restart-local"] {
      #expect(DesktopRuntimeProfile.current.desktopCommands.contains(command))
    }
  }

  /// A stand-in runtime, including the notice main.swift emits before parsing --version.
  static func runtime(
    versionOutput: String = "0.9.20", versionExitCode: Int = 0,
    help: String = releasedTopLevelHelp, emitUpgradeNotice: Bool = true
  ) throws -> (directory: URL, script: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("darkbloom")
    try writeRuntime(at: script, versionOutput: versionOutput, versionExitCode: versionExitCode,
      help: help, emitUpgradeNotice: emitUpgradeNotice)
    return (directory, script)
  }

  static func writeRuntime(
    at script: URL, versionOutput: String, versionExitCode: Int = 0,
    help: String = releasedTopLevelHelp, emitUpgradeNotice: Bool = true
  ) throws {
    let notice = try #require(MacOSUpgradeNotice.message(
      for: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
    try """
    #!/bin/sh
    cat >&2 <<'NOTICE'
    \(emitUpgradeNotice ? notice : "")
    NOTICE
    case "$1" in
      --version)
        cat <<'VERSION'
    \(versionOutput)
    VERSION
        exit \(versionExitCode)
        ;;
      fan) printf '%s' '{"loaded":true,"helper":{"mode":"automatic"},"diagnostic":{"supported":true,"fans":[],"gpuTemperatures":[]}}' ;;
      *) cat <<'HELP'
    \(help)
    HELP
      ;;
    esac
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  }

  @Test func reportsTheRuntimeDespiteStderrUpgradeNoticeAndRejectsMissingCommands() async throws {
    let (directory, script) = try Self.runtime()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)

    let profile = await backend.runtimeProfile()
    #expect(profile.version == "0.9.20")
    #expect(profile.desktopCommands.isEmpty)
    #expect(await backend.runtimeProfile() == profile)

    await #expect(throws: (any Error).self) {
      try await backend.requireRuntimeSupport(["desktop", "configure-cooling", "--enabled", "true"])
    }
    do {
      try await backend.requireRuntimeSupport(["desktop", "start-local"])
      Issue.record("start-local should need a newer runtime")
    } catch {
      #expect(String(describing: error).contains("Darkbloom 0.9.20 doesn’t support this yet"))
    }
    // Commands the released runtime has are unaffected.
    try await backend.requireRuntimeSupport(["update"])
    try await backend.requireRuntimeSupport(["start", "--model", "m"])
  }

  @Test func coolingControlIsUnavailableWithoutTheRuntimeCommand() async throws {
    // Keep the existing fan JSON fixture clean; its stderr handling is a separate path.
    let (directory, script) = try Self.runtime(emitUpgradeNotice: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let cooling = try await backend.resource("cooling")
    #expect(cooling.field("supported").flag == true)
    #expect(cooling.field("control_available").flag == false)
  }

  @Test func aReplacedRuntimeIsReadAgain() async throws {
    let (directory, script) = try Self.runtime()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    #expect(await backend.runtimeProfile().version == "0.9.20")
    // An update replaces the executable (new inode), so the next read sees the new version.
    let updated = directory.appendingPathComponent("darkbloom.new")
    try Self.writeRuntime(at: updated, versionOutput: "0.9.21", help: Self.desktopHelp)
    _ = try FileManager.default.replaceItemAt(script, withItemAt: updated)
    let profile = await backend.runtimeProfile()
    #expect(profile.version == "0.9.21")
    #expect(profile.desktopCommands == ["serve", "configure-cooling", "start-local"])
    try await backend.requireRuntimeSupport(["desktop", "configure-cooling"])
  }

  @Test(arguments: [
    ("", 0),
    ("not a version", 0),
    ("Warning: stdout diagnostic\n0.9.20", 0),
    ("0.9.20\nAnother stdout log line", 0),
    ("0.9.20", 1),
  ])
  func invalidOrFailedVersionProbesStillDiscoverCapabilities(output: String, exitCode: Int) async throws {
    try await assertUnavailableVersion(output: output, exitCode: exitCode)
  }

  @Test func truncatedVersionOutputIsNotAccepted() async throws {
    // Truncating this prefix would leave an apparently valid version. Fail closed instead.
    try await assertUnavailableVersion(output: String(repeating: " ", count: 65_536) + "0.9.20", exitCode: 0)
  }

  private func assertUnavailableVersion(output: String, exitCode: Int) async throws {
    let (directory, script) = try Self.runtime(
      versionOutput: output, versionExitCode: exitCode, help: Self.desktopHelp)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)

    let profile = await backend.runtimeProfile()
    #expect(profile.version == nil)
    #expect(profile.desktopCommands == ["serve", "configure-cooling", "start-local"])
    try await backend.requireRuntimeSupport(["desktop", "start-local"])
  }

  @Test func aCancelledProbeDoesNotCacheAnUnavailableProfile() async throws {
    let (directory, script) = try Self.runtime(help: Self.desktopHelp)
    defer { try? FileManager.default.removeItem(at: directory) }
    let started = directory.appendingPathComponent("started")
    let original = try String(contentsOf: script, encoding: .utf8)
    try """
      #!/bin/sh
      if [ "$1" = --version ] && [ ! -e '\(started.path)' ]; then
        trap '' TERM
        echo started > '\(started.path)'
        exec /bin/sleep 30
      fi
      \(original)
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let task = Task { await backend.runtimeProfile() }
    defer { task.cancel() }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: started.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    task.cancel()
    _ = await task.value
    let profile = await backend.runtimeProfile()
    #expect(profile.version == "0.9.20")
    #expect(profile.desktopCommands == ["serve", "configure-cooling", "start-local"])
  }
}
