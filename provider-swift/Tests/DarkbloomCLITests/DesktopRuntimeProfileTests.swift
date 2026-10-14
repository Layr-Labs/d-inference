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

  /// A stand-in for an older installed runtime: version 0.9.20, no `desktop` group.
  static func olderRuntime() throws -> (directory: URL, script: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("darkbloom")
    try """
    #!/bin/sh
    case "$1" in
      --version) echo 0.9.20 ;;
      fan) printf '%s' '{"loaded":true,"helper":{"mode":"automatic"},"diagnostic":{"supported":true,"fans":[],"gpuTemperatures":[]}}' ;;
      *) cat <<'HELP'
    \(Self.releasedTopLevelHelp)
    HELP
      ;;
    esac
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (directory, script)
  }

  @Test func reportsAnOlderInstalledRuntimeAndRejectsItsMissingCommands() async throws {
    let (directory, script) = try Self.olderRuntime()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)

    let profile = await backend.runtimeProfile()
    #expect(profile.version == "0.9.20")
    #expect(profile.desktopCommands.isEmpty)

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
    let (directory, script) = try Self.olderRuntime()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let cooling = try await backend.resource("cooling")
    #expect(cooling.field("supported").flag == true)
    #expect(cooling.field("control_available").flag == false)
  }

  @Test func aReplacedRuntimeIsReadAgain() async throws {
    let (directory, script) = try Self.olderRuntime()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    #expect(await backend.runtimeProfile().version == "0.9.20")
    // An update replaces the executable (new inode), so the next read sees the new version.
    let updated = directory.appendingPathComponent("darkbloom.new")
    try "#!/bin/sh\n[ \"$1\" = --version ] && echo 0.9.21\n"
      .write(to: updated, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updated.path)
    _ = try FileManager.default.replaceItemAt(script, withItemAt: updated)
    #expect(await backend.runtimeProfile().version == "0.9.21")
  }
}
