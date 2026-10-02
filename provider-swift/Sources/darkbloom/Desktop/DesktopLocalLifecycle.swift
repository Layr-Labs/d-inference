import ArgumentParser
import Foundation
import ProviderCore

enum DesktopLocalLifecycle {
  static var isActive: Bool {
    guard let local = LocalEndpoint.readLiveInfo(),
      let owner = LaunchAgent.launchSnapshot()?.process,
      owner.pid == local.pid, owner.isCurrent()
    else { return false }
    let state = DaemonStateFile.read()
    // Combined mode belongs to the ordinary provider drain protocol.
    return state?.processIdentity != owner
  }

  static func stop(configPath: String?) async throws {
    guard let local = LocalEndpoint.readLiveInfo(),
      let owner = LaunchAgent.launchSnapshot()?.process,
      owner.pid == local.pid, owner.isCurrent(), isActive
    else { throw ValidationError("Cannot verify the local runtime owner") }
    let config = try loadRuntimeConfiguration(configPath: configPath).config
    let lease = try SelfUpdater(coordinatorBaseURL: config.coordinator.url).beginUpdateSession(
      operation: "desktop-local-stop", timeout: 0)
    defer { lease.release() }
    try WatchdogAgent.stop()
    try LaunchAgent.disableAutomaticStartup()
    // The signed CLI's AppKit signal handler calls StandaloneServer.drainAndStop.
    try ProcessLifecycle.requestTermination(owner)
    let deadline = ContinuousClock.now.advanced(by: .seconds(620))
    while owner.isCurrent(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(200))
    }
    guard !owner.isCurrent() else {
      throw ValidationError(
        "Local requests are still draining. Automatic restart remains disabled.")
    }
    try LaunchAgent.stop()
  }
}

extension Desktop {
  struct StopLocal: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    mutating func run() async throws {
      try await DesktopLocalLifecycle.stop(configPath: configOptions.config)
      print("Local provider stopped")
    }
  }
  struct RestartLocal: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    mutating func run() async throws {
      try await DesktopLocalLifecycle.stop(configPath: configOptions.config)
      try LaunchAgent.restartAfterDrain()
      print("Local provider restarted")
    }
  }
}
