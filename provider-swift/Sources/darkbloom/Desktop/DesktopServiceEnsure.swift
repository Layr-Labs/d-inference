import ArgumentParser
import Darwin
import Foundation
import ProviderCore

extension DesktopService {
  /// Install, refresh or restart the agent until its API answers as this CLI's
  /// version. Never restarts an API that reports a running operation
  /// (`nextStep`); restarting marks the old API's operations `interrupted`.
  static func ensure(configPath: String?) async throws {
    try DesktopStorage.prepare()
    let path = plistPath()
    let desired = plist(
      executable: try FanServiceManager().currentExecutableURL().path,
      configPath: absoluteConfigPath(configPath), logDirectory: DesktopStorage.directory)
    var restarted = false
    var previousInstance: String?
    while true {
      let loaded = LaunchAgent.isLoaded(agentLabel: label)
      let current = isCurrent(installed: try? Data(contentsOf: path), desired: desired)
      let observation =
        loaded
        ? await observe(until: .now + .seconds(restarted ? 25 : 10), excluding: previousInstance)
        : .noAnswer
      let step = nextStep(
        loaded: loaded, plistCurrent: current, observation: observation,
        expectedVersion: ProviderCore.version, restarted: restarted)
      // Readiness after a deliberate restart must come from a new process.
      previousInstance =
        step == .reinstall || step == .restart
        ? DesktopStorage.read(DesktopDiscovery.self, name: "connection.json")?.instance : nil
      switch step {
      case .ready:
        print("Desktop API ready")
        return
      case .deferred:
        print("Desktop API ready; it restarts after its running operation finishes")
        return
      case .fail(let message):
        throw ValidationError(message)
      case .install:
        try write(desired, to: path)
        try LaunchAgent.bootstrap(agentLabel: label, plist: path)
      case .reinstall:
        try LaunchAgent.bootout(agentLabel: label)
        let deadline = ContinuousClock.now + .seconds(5)
        while LaunchAgent.isLoaded(agentLabel: label) {
          // Bootstrapping now would leave the stale job running.
          guard ContinuousClock.now < deadline else {
            throw ValidationError("The old desktop API LaunchAgent did not unload")
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        // launchd can briefly refuse a bootstrap right after bootout.
        try await Task.sleep(for: .milliseconds(200))
        try write(desired, to: path)
        try LaunchAgent.bootstrap(agentLabel: label, plist: path)
      case .restart:
        do {
          try LaunchAgent.kickstart(agentLabel: label)
        } catch {
          guard !LaunchAgent.isLoaded(agentLabel: label) else { throw error }
        }
        // The job vanished since it was observed: load it, still the one restart.
        if !LaunchAgent.isLoaded(agentLabel: label) {
          try LaunchAgent.bootstrap(agentLabel: label, plist: path)
        }
      }
      restarted = true
    }
  }

  private static func write(_ plist: [String: Any], to path: URL) throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: path, options: .atomic)
  }

  /// The first answer from a live published API other than `excluding`, or
  /// `.noAnswer` at the deadline. Transport errors are retried.
  private static func observe(
    until deadline: ContinuousClock.Instant, excluding: String?
  ) async -> Observation {
    struct State: Decodable {
      struct Operation: Decodable { let state: String }
      let version: String?
      let operations: [Operation]?
    }
    while ContinuousClock.now < deadline {
      if let connection = DesktopStorage.read(DesktopDiscovery.self, name: "connection.json"),
        connection.instance != excluding, kill(connection.pid, 0) == 0
      {
        var request = URLRequest(
          url: URL(string: "http://127.0.0.1:\(connection.port)/control/v1/state")!)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        if let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
        {
          guard http.statusCode == 200 else { return .failed(status: http.statusCode) }
          let state = try? JSONDecoder().decode(State.self, from: data)
          return .answered(
            version: state?.version ?? "unknown",
            runningOperation: state?.operations?.contains { $0.state == "running" } ?? false)
        }
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return .noAnswer
  }
}
