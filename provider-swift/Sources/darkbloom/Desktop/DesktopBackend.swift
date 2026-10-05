import ArgumentParser
import Darwin
import Foundation
import ProviderCore

actor DesktopBackend {
  let configPath: String?
  /// CLI used for child operations; nil means this process's own executable.
  let executable: URL?
  /// Stamp of the binary this API started from (`exitWhenExecutableReplaced`).
  let startupExecutableStamp = DesktopBackend.currentExecutableStamp()
  let instance = UUID().uuidString
  var cachedConfiguration: RuntimeConfiguration?
  var cachedConfigurationRevision: String?
  var operations: [DesktopOperation] = []
  private var requests: [String: DesktopAction] = [:]
  private var workers: [String: DesktopWorker] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  private var cancellationRequested: Set<String> = []
  var catalog: [CatalogModel] = []
  var catalogError: String?
  var catalogAt = Date.distantPast
  var catalogTask: Task<Void, Never>?
  var resourceGeneration = 0
  var resourceFailures: [String: (attempts: Int, retryAt: Date)] = [:]
  var resourceCache: [String: DesktopResourceCache] = [:]
  var resourceTasks: [String: Task<JSONValue, Error>] = [:]
  var localAt = Date.distantPast
  var localModels: [ModelInfo] = []
  var link: JSONValue = .null
  var samples: [JSONValue] = []
  var sampleSession: Double?
  var accountEarningsCache: (key: String, at: Date, value: JSONValue)?
  var accountEarningsTask: (key: String, task: Task<JSONValue, Error>)?
  var usageArchive = DesktopUsageArchive()
  var usageReadAt = Date.distantPast
  var usageRead: Task<Void, Never>?
  var accountSession = DesktopAccountSession()
  /// Shared `fan status` read; `coolingReadAt` is nil while it is in flight.
  var coolingRead: Task<JSONValue, Never>?
  var coolingReadAt: Date?

  init(configPath: String?, executable: URL? = nil) {
    self.configPath = configPath
    self.executable = executable
    operations = DesktopStorage.read([DesktopOperation].self, name: "operations.json") ?? []
    for i in operations.indices where operations[i].state == "running" {
      operations[i].state = "interrupted"
      operations[i].message =
        "The control connection restarted. Check current state before retrying."
    }
  }

  func submit(_ request: DesktopAction) throws -> DesktopOperation {
    try request.validate()
    if let original = requests[request.id] {
      guard original == request, let operation = operations.first(where: { $0.id == request.id })
      else { throw ValidationError("Request ID was already used") }
      return operation
    }
    if request.action == "cancel" {
      guard let id = request.operation, let index = operations.firstIndex(where: { $0.id == id }),
        operations[index].state == "running", operations[index].cancellable
      else { throw ValidationError("This operation cannot be cancelled") }
      cancellationRequested.insert(id)
      workers[id]?.cancel()
      tasks[id]?.cancel()
      // Keep the mutation slot until the child exits or the native task unwinds.
      operations[index].cancellable = false
      operations[index].message = "Cancelling…"
      persist()
      return operations[index]
    }
    guard !operations.contains(where: { $0.state == "running" }) else {
      throw ValidationError("An operation is already running. Wait for it to finish.")
    }
    let operation = DesktopOperation(
      id: request.id, action: request.action, started_at: Date().timeIntervalSince1970,
      cancellable: ["download", "diagnose", "link", "account-signin"].contains(request.action))
    requests[request.id] = request
    operations.insert(operation, at: 0)
    operations = Array(operations.prefix(32))
    requests = requests.filter { key, _ in operations.contains { $0.id == key } }
    persist()
    tasks[request.id] = Task { await self.execute(request) }
    return operation
  }

  private func execute(_ request: DesktopAction) async {
    defer {
      workers[request.id] = nil
      tasks[request.id] = nil
      cancellationRequested.remove(request.id)
      localAt = .distantPast
      operationFinished(request.action)
    }
    do {
      try Task.checkCancellation()
      if request.action == "settings" {
        try withMutableConfig(configPath: configPath) { path, config in
          guard DesktopStorage.revision(path) == request.revision else {
            throw ValidationError("Settings changed. Refresh and try again.")
          }
          config.provider.name = request.name!
          config.provider.autoUpdate = request.auto_update!
          config.backend.idleTimeoutMins = request.idle_minutes!
          if let schedule = request.schedule { config.schedule = schedule }
          if let preload = request.startup_preload { config.backend.startupPreload = preload }
          try ConfigManager.save(config, to: path)
        }
        complete(
          request.id, code: 0,
          message: "Settings saved. Restart the provider to apply runtime changes.")
      } else if ["account-signin", "account-signout"].contains(request.action) {
        try await executeAccountAction(request)
      } else if request.action == "link" {
        guard AuthTokenStore.load() == nil else {
          throw ValidationError("This Mac is already linked")
        }
        let config = try loadRuntimeConfiguration(configPath: configPath).config
        _ = try await performDeviceCodeLogin(
          coordinatorURL: config.coordinator.url,
          onDisplayCode: { [weak self] code, url, seconds in
            Task {
              await self?.setLink(request.id,
                .dict([
                  "url": .string(url), "code": .string(code),
                  "expires_at": .number(Date().timeIntervalSince1970 + Double(seconds)),
                  "state": .string("waiting"),
                ]))
            }
          })
        link = .null
        complete(request.id, code: 0, message: "This Mac is linked to your account.")
      } else {
        if request.action == "start", request.local != true, DesktopLocalLifecycle.isActive {
          try await DesktopLocalLifecycle.stop(configPath: configPath)
        }
        let arguments = try arguments(for: request)
        try Task.checkCancellation()
        let worker = DesktopWorker(executable: executable)
        workers[request.id] = worker
        let before = Self.currentExecutableStamp()
        let (code, output) = try await worker.run(
          arguments,
          progress: { [weak self] output in
            Task { await self?.setProgress(request.id, output: output) }
          })
        complete(request.id, code: code, message: output)
        if request.action == "update", code == 0,
          Self.shouldRestartForReplacedExecutable(
            startup: before, current: Self.currentExecutableStamp(), hasRunningOperation: false)
        {
          // launchd reopens the replacement CLI after the native updater commits it.
          Darwin.exit(0)
        }
      }
    } catch {
      if ["link", "account-signin"].contains(request.action) { link = .null }
      complete(request.id, code: 1, message: String(describing: error))
    }
  }

  func arguments(for request: DesktopAction) throws -> [String] {
    if request.action == "remove" {
      let state = DaemonStateFile.read()
      guard !(state?.warmModels.contains(request.model!) ?? false),
        !(state?.advertisedModels?.contains(request.model!) ?? false)
      else { throw ValidationError("Stop serving this model before removing it") }
    }
    return try Self.arguments(
      for: request, configPath: configPath, localActive: DesktopLocalLifecycle.isActive)
  }

  /// Argv for a validated action. `--config` goes only to commands declaring
  /// `ConfigOptions`: `switch` reuses the live provider's config and `stop`
  /// and `logout` take none.
  static func arguments(
    for request: DesktopAction, configPath: String?, localActive: @autoclosure () -> Bool
  ) throws -> [String] {
    let config = configPath.map { ["--config", $0] } ?? []
    let models = (request.models ?? []).flatMap { ["--model", $0] }
    switch request.action {
    case "start":
      guard request.local != true else { return ["desktop", "start-local"] + models + config }
      return ["start"] + models + (request.endpoint == true ? ["--local-endpoint"] : []) + config
    case "switch":
      return localActive() ? ["desktop", "start-local"] + models + config : ["switch"] + models
    case "stop": return localActive() ? ["desktop", "stop-local"] + config : ["stop"]
    case "restart": return (localActive() ? ["desktop", "restart-local"] : ["restart"]) + config
    case "update": return ["update"] + config
    case "diagnose": return ["doctor"] + config
    case "unlink": return ["logout"]
    case "download": return ["models", "download", request.model!] + config
    case "remove": return ["models", "remove", request.model!, "--force"] + config
    case "cooling":
      return [
        "desktop", "configure-cooling", "--enabled", request.enabled == true ? "true" : "false",
        "--speed", String(request.speed ?? 70), "--temperature", String(request.temperature ?? 50),
      ]
    default: throw ValidationError("Unsupported action")
    }
  }

  func setLink(_ id: String, _ value: JSONValue) {
    guard !cancellationRequested.contains(id),
      operations.contains(where: { $0.id == id && $0.state == "running" })
    else { return }
    link = value
  }
  private func setProgress(_ id: String, output: String) {
    guard let index = operations.firstIndex(where: { $0.id == id }),
      operations[index].state == "running"
    else { return }
    operations[index].message = String(output.suffix(8000))
  }
  func complete(_ id: String, code: Int32, message: String) {
    guard let index = operations.firstIndex(where: { $0.id == id }),
      operations[index].state == "running"
    else { return }
    let cancelled = cancellationRequested.contains(id)
    operations[index].state = cancelled ? "cancelled" : (code == 0 ? "succeeded" : "failed")
    operations[index].finished_at = Date().timeIntervalSince1970
    operations[index].message = cancelled ? "Cancelled" : String(message.suffix(8000))
    persist()
  }
  func persist() { try? DesktopStorage.write(operations, name: "operations.json") }
}
