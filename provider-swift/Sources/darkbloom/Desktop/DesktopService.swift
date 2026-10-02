import Foundation
import ProviderCore

/// The user LaunchAgent that keeps the desktop control API running.
/// `desktop ensure` installs and refreshes it; `stop --uninstall` removes it.
enum DesktopService {
  static let label = "io.darkbloom.desktop-api"

  static func plistPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  /// The plist `ensure` installs. `ExitTimeOut` bounds a restart's graceful
  /// shutdown, which would otherwise wait on open event streams.
  static func plist(executable: String, configPath: String?, logDirectory: URL) -> [String: Any] {
    var arguments = [executable, "desktop", "serve"]
    if let configPath { arguments += ["--config", configPath] }
    let log = logDirectory.appendingPathComponent("service.log").path
    return [
      "Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "KeepAlive": true,
      "ThrottleInterval": 10, "ExitTimeOut": 5, "StandardOutPath": log, "StandardErrorPath": log,
      "ProcessType": "Background",
    ]
  }

  /// Whether the installed plist is exactly the one `ensure` would write.
  static func isCurrent(installed: Data?, desired: [String: Any]) -> Bool {
    guard let installed,
      let plist = try? PropertyListSerialization.propertyList(from: installed, format: nil)
        as? [String: Any]
    else { return false }
    return NSDictionary(dictionary: plist).isEqual(to: desired)
  }

  /// How the published API answered `GET /control/v1/state`.
  enum Observation: Equatable {
    case noAnswer
    /// Answered with a non-200 status, for example because the config is broken.
    case failed(status: Int)
    case answered(version: String, runningOperation: Bool)
  }

  enum Step: Equatable {
    case ready
    /// A restart or reinstall is due, but the API is running an operation.
    /// Its replaced-executable check restarts it afterwards; a changed plist
    /// is applied by the next `ensure`.
    case deferred
    /// Not loaded: write the plist and bootstrap it.
    case install
    /// Loaded, but the plist on disk differs: bootout, rewrite, bootstrap.
    case reinstall
    /// Loaded and current, but no answer or another version.
    case restart
    case fail(String)
  }

  /// The next `ensure` step. At most one install/reinstall/restart happens per
  /// invocation (`restarted`); a mismatch that survives it fails instead of
  /// looping. Never restarts during a running operation: the API owns its
  /// children's output pipes, so killing it kills them too.
  static func nextStep(
    loaded: Bool, plistCurrent: Bool, observation: Observation, expectedVersion: String,
    restarted: Bool
  ) -> Step {
    let notLoaded = "The desktop API LaunchAgent did not load"
    guard loaded else { return restarted ? .fail(notLoaded) : .install }
    if restarted, !plistCurrent { return .fail(notLoaded) }
    switch observation {
    case .answered(let version, let running):
      if plistCurrent, version == expectedVersion { return .ready }
      if running { return .deferred }
      if restarted {
        return .fail(
          "Desktop API still reports version \(version) after a restart; expected \(expectedVersion)"
        )
      }
      return plistCurrent ? .restart : .reinstall
    case .failed(let status):
      // Restarting the same plist cannot fix an API that answers with an
      // error; new arguments (for example another --config) might.
      guard plistCurrent else { return .reinstall }
      return .fail("Desktop API answered HTTP \(status). Check the provider configuration.")
    case .noAnswer:
      if restarted { return .fail("Desktop API did not become ready") }
      return plistCurrent ? .restart : .reinstall
    }
  }

  /// launchd starts agents in `/`, so a relative `--config` is made absolute
  /// (tilde-expanded, standardized) before it is written into the plist.
  static func absoluteConfigPath(
    _ path: String?, relativeTo directory: String = FileManager.default.currentDirectoryPath
  ) -> String? {
    guard let path else { return nil }
    let base = URL(fileURLWithPath: directory, isDirectory: true)
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: base)
      .standardizedFileURL.path
  }

  /// Unload the agent, then delete its plist even if the unload failed so it
  /// cannot return at the next login. The unload error is rethrown afterwards.
  static func uninstall(
    plist: URL = plistPath(),
    unload: () throws -> Void = { try LaunchAgent.bootout(agentLabel: label) }
  ) throws {
    var unloadError: (any Error)?
    do { try unload() } catch { unloadError = error }
    if FileManager.default.fileExists(atPath: plist.path) {
      try FileManager.default.removeItem(at: plist)
    }
    if let unloadError { throw unloadError }
  }
}
