import ArgumentParser
import Foundation
import ProviderCore

/// What the CLI that runs child operations offers. In attach-only mode (a local desktop
/// preview) this API drives the installed, vendor-signed runtime, which can be older than the
/// API itself: it reports its own version, and it may lack the `desktop` subcommands.
struct DesktopRuntimeProfile: Equatable, Sendable {
  /// The runtime's `--version`; nil when it could not be read.
  var version: String?
  /// `desktop` subcommands the runtime accepts.
  var desktopCommands: Set<String>

  /// This process's own executable, which offers everything it was built with.
  static let current = DesktopRuntimeProfile(
    version: ProviderCore.version,
    // `_commandName` is the name ArgumentParser derives from the type (ConfigureCooling →
    // configure-cooling) when the configuration doesn't set one.
    desktopCommands: Set(Desktop.configuration.subcommands.map { $0._commandName }))

  /// Accept only a version, not a version-looking line embedded in stdout diagnostics.
  static func parseVersion(_ output: String) -> String? {
    let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard version.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    else { return nil }
    return version
  }

  /// Subcommands listed by `desktop --help`. A runtime without the group prints its top-level
  /// help instead (and still exits 0), so the usage line must name `desktop`.
  static func parseDesktopCommands(_ help: String) -> Set<String> {
    guard help.contains("USAGE: darkbloom desktop ") else { return [] }
    guard let start = help.range(of: "SUBCOMMANDS:") else { return [] }
    return Set(
      help[start.upperBound...].split(whereSeparator: \.isNewline).compactMap { line in
        guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return nil }
        return line.split(separator: " ").first.map(String.init)
      })
  }
}

extension DesktopBackend {
  /// The child-operation runtime's profile, read once per installed executable: an update or
  /// repair replaces the file, which changes its stamp and triggers a fresh read.
  func runtimeProfile() async -> DesktopRuntimeProfile {
    guard let executable else { return .current }
    let stamp = Self.executableStamp(at: executable.path)
    if let cached = runtimeProfileCache, cached.stamp == stamp, stamp != Self.unknownExecutableStamp {
      return cached.profile
    }
    let worker = DesktopWorker(executable: executable)
    let version = (try? await worker.run(["--version"], timeout: 15, capture: .standardOutput))
      .flatMap { $0.0 == 0 ? DesktopRuntimeProfile.parseVersion($0.1) : nil }
    let help = (try? await worker.run(["desktop", "--help"], timeout: 15))?.1 ?? ""
    let profile = DesktopRuntimeProfile(
      version: version, desktopCommands: DesktopRuntimeProfile.parseDesktopCommands(help))
    // Cancellation is not a property of the executable; let the next caller probe it again.
    if !Task.isCancelled { runtimeProfileCache = (stamp, profile) }
    return profile
  }

  /// Rejects an action whose `desktop` subcommand the installed runtime does not have, with a
  /// message that says why, instead of letting the runtime print its usage text.
  func requireRuntimeSupport(_ arguments: [String]) async throws {
    guard arguments.first == "desktop", arguments.count > 1 else { return }
    let profile = await runtimeProfile()
    guard !profile.desktopCommands.contains(arguments[1]) else { return }
    let installed = profile.version.map { "Darkbloom \($0)" } ?? "The installed Darkbloom runtime"
    throw ValidationError(
      "\(installed) doesn’t support this yet. It needs a runtime release that includes the desktop app’s commands.")
  }
}
