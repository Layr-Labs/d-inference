import ArgumentParser
import Darwin
import Foundation
import Hummingbird
import ProviderCore
import Security

struct Desktop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Serve the authenticated desktop control API.",
    subcommands: [
      Serve.self, Ensure.self, StartLocal.self, ConfigureCooling.self, StopLocal.self,
      RestartLocal.self,
    ])

  struct Serve: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    /// Tests shorten this; launchd always runs the default.
    @Option(help: .hidden) var replacementCheckSeconds: Int = 30
    mutating func validate() throws {
      guard (1...300).contains(replacementCheckSeconds) else {
        throw ValidationError("--replacement-check-seconds must be between 1 and 300")
      }
    }
    mutating func run() async throws {
      try DesktopStorage.prepare()
      let fd = open(
        DesktopStorage.directory.appendingPathComponent("service.lock").path,
        O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        throw ValidationError("Desktop API is already running")
      }
      defer { close(fd) }
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw ValidationError("Could not create API credential")
      }
      let token = Data(bytes).base64EncodedString()
      let instance = UUID().uuidString
      let backend = DesktopBackend(configPath: configOptions.config)
      let app = Application(
        responder: DesktopHTTP(backend: backend, token: token),
        configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { channel in
          do {
            guard let port = channel.localAddress?.port else {
              throw ValidationError("API bind failed")
            }
            try DesktopStorage.write(
              DesktopDiscovery(
                version: 1, port: port, token: token, pid: getpid(), instance: instance),
              name: "connection.json")
          } catch {
            printError("Cannot publish desktop API discovery: \(error)")
            Darwin.exit(1)
          }
        })
      let updates = Task { await backend.automaticUpdates() }
      defer { updates.cancel() }
      let interval = Duration.seconds(replacementCheckSeconds)
      let replacement = Task { await backend.exitWhenExecutableReplaced(every: interval) }
      defer { replacement.cancel() }
      try await app.runService()
    }
  }

  struct Ensure: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    mutating func run() async throws {
      try await DesktopService.ensure(configPath: configOptions.config)
    }
  }

  struct StartLocal: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    @Option var model: [String] = []
    mutating func run() async throws {
      guard !model.isEmpty else { throw ValidationError("Select a model") }
      try model.forEach(DesktopAction.validateModel)
      if DesktopLocalLifecycle.isActive {
        try await DesktopLocalLifecycle.stop(configPath: configOptions.config)
      }
      let session = try await ServiceDrain.prepare(options: DrainOptions())
      defer { session.release() }
      try await ServiceDrain.stopDrainedProvider()
      try LaunchAgent.installLocalAndStart(
        models: model, configPath: configOptions.config.map { URL(fileURLWithPath: $0) })
      print("Local inference service started")
    }
  }

  struct ConfigureCooling: AsyncParsableCommand {
    @Option var enabled: Bool
    @Option var speed: Int = 70
    @Option var temperature: Int = 50
    mutating func run() async throws {
      guard (30...100).contains(speed), (40...90).contains(temperature) else {
        throw ValidationError("Invalid fan policy")
      }
      let executable = try FanServiceManager().currentExecutableURL()
      // Verify the existing provisioned CLI/helper before asking macOS for administrator authorization.
      _ = try FanServiceManager().bundledHelperURL()
      let command =
        "/usr/bin/env SUDO_UID=\(getuid()) SUDO_GID=\(getgid()) \(Self.quote(executable.path)) fan \(enabled ? "enable --speed \(speed) --temperature \(temperature)" : "disable")"
      let script = "do shell script \(Self.appleString(command)) with administrator privileges"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw ValidationError("Cooling authorization cancelled or failed")
      }
    }
    static func quote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func appleString(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "\"", with: "\\\"") + "\""
    }
  }
}
