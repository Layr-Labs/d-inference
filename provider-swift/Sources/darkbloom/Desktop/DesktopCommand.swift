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
      RestartLocal.self, Login.self, Logout.self,
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
      // Local review builds attach to an existing installation; serving operations
      // must keep using its verified CLI rather than installing this ad-hoc build.
      let worker = ProcessInfo.processInfo.environment["DARKBLOOM_DESKTOP_ATTACH_ONLY"] == "1"
        ? try DesktopFanRuntime.resolve() : nil
      let backend = DesktopBackend(configPath: configOptions.config, executable: worker)
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

    /// The drain's options, as `darkbloom stop` would take them with none given.
    static func drainOptions() throws -> DrainOptions { try DrainOptions.parse([]) }

    /// The local API the app's local mode serves: this Mac's one port (`LocalAPIPort.thisMac`: the saved one, else one
    /// chosen and saved now), and `[local] bind`.
    static func localAPI(configPath: String?, ownLivePort: () -> UInt16? = LocalAPIPort.ownLivePort,
                         isFree: (UInt16) -> Bool = LocalAPIPort.isFreeOnThisMac)
      throws -> (choice: LocalAPIPort.Choice, bind: String) {
      let loaded = try loadRuntimeConfiguration(configPath: configPath)
      let choice = try LocalAPIPort.thisMac(configPath: loaded.configPath, fallbackConfig: loaded.config,
                                            ownLivePort: ownLivePort, isFree: isFree)
      return (choice, loaded.config.local?.resolvedBind ?? LocalSettings.defaultBind)
    }

    /// On a Mac in a two-Mac cluster: why local mode starts nothing; nil elsewhere.
    static func pairRefusal(_ pair: ClusterPairSummary) -> [String]? {
      guard pair.paired else { return nil }
      return ["This Mac is in a two-Mac cluster with \(pair.otherMac): the app's local mode serves this Mac alone, so nothing was started.",
              "To serve the pair locally: `\(ClusterPairSummary.cli) cluster local` on the leading Mac. To serve this Mac alone: stop the pair "
                + "(`\(ClusterPairSummary.cli) stop`), then `\(ClusterPairSummary.cli) start --solo --local --model <id>`."]
    }
    mutating func run() async throws {
      guard !model.isEmpty else { throw ValidationError("Select a model") }
      try model.forEach(DesktopAction.validateModel)
      // Its launchd job (`start --foreground --local …`) serves this Mac alone, and as launchd's child it skips the
      // checks `start` makes on a paired Mac: say so now, never "started".
      if let refusal = Self.pairRefusal(ClusterPairSummary.local()) {
        for line in refusal { printError(line) }
        throw ExitCode.failure
      }
      // Before anything stops: no free port starts nothing.
      let api: (choice: LocalAPIPort.Choice, bind: String)
      do {
        api = try Self.localAPI(configPath: configOptions.config)
      } catch let none as LocalAPIPortError {
        throw ValidationError(none.description)
      }
      if DesktopLocalLifecycle.isActive {
        try await DesktopLocalLifecycle.stop(configPath: configOptions.config)
      }
      let session = try await ServiceDrain.prepare(options: try Self.drainOptions())
      defer { session.release() }
      try await ServiceDrain.stopDrainedProvider()
      try LaunchAgent.installLocalAndStart(
        models: model, configPath: configOptions.config.map { URL(fileURLWithPath: $0) }, port: api.choice.port,
        bind: api.bind, noAuth: false)
      if let note = api.choice.note { print(note) }
      print("Local inference service started")
    }
  }

  struct ConfigureCooling: AsyncParsableCommand {
    @Option var enabled: Bool
    @Option var speed: Int = 70
    @Option var temperature: Int = 50
    mutating func run() async throws {
      guard (60...90).contains(speed), (40...90).contains(temperature) else {
        throw ValidationError("Invalid fan policy")
      }
      let executable = try DesktopFanRuntime.resolve()
      let command =
        "/usr/bin/env SUDO_UID=\(getuid()) SUDO_GID=\(getgid()) \(Self.quote(executable.path)) fan \(enabled ? "enable --speed \(speed) --temperature \(temperature)" : "disable")"
      let script = "do shell script \(Self.appleString(command)) with administrator privileges"
      let output = try await DesktopCoolingAuthorization.perform(script: script)
      if !output.isEmpty { print(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
