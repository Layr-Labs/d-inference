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
      try await app.runService()
    }
  }

  struct Ensure: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    mutating func run() async throws {
      try DesktopStorage.prepare()
      let label = "io.darkbloom.desktop-api"
      let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/LaunchAgents/\(label).plist")
      var arguments = [try FanServiceManager().currentExecutableURL().path, "desktop", "serve"]
      if let config = configOptions.config { arguments += ["--config", config] }
      let contents: [String: Any] = [
        "Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "KeepAlive": true,
        "ThrottleInterval": 10,
        "StandardOutPath": DesktopStorage.directory.appendingPathComponent("service.log").path,
        "StandardErrorPath": DesktopStorage.directory.appendingPathComponent("service.log").path,
        "ProcessType": "Background",
      ]
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        .write(to: plist, options: .atomic)
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      task.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      try task.run()
      task.waitUntilExit()
      // An already bootstrapped service is success only after its authenticated API responds.
      for _ in 0..<50 {
        if let connection = DesktopStorage.read(DesktopDiscovery.self, name: "connection.json"),
          kill(connection.pid, 0) == 0
        {
          var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(connection.port)/control/v1/state")!)
          request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
          request.timeoutInterval = 2
          if let (_, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
          {
            print("Desktop API ready")
            return
          }
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      throw ValidationError("Desktop API did not become ready")
    }
  }

  struct StartLocal: AsyncParsableCommand {
    @OptionGroup var configOptions: ConfigOptions
    @Option var model: [String] = []
    mutating func run() async throws {
      guard !model.isEmpty else { throw ValidationError("Select a model") }
      try model.forEach(DesktopAction.validateModel)
      if DesktopLocalLifecycle.isActive { try await DesktopLocalLifecycle.stop() }
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
