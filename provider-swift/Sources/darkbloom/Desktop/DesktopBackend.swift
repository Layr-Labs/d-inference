import ArgumentParser
import Darwin
import Foundation
import ProviderCore

actor DesktopBackend {
  let configPath: String?
  let instance = UUID().uuidString
  var cachedConfiguration: RuntimeConfiguration?
  var cachedConfigurationRevision: String?
  var operations: [DesktopOperation] = []
  private var requests: [String: DesktopAction] = [:]
  private var workers: [String: DesktopWorker] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  var catalog: [CatalogModel] = []
  var catalogError: String?
  var catalogAt = Date.distantPast
  var localAt = Date.distantPast
  var localModels: [ModelInfo] = []
  var link: JSONValue = .null
  var samples: [JSONValue] = []
  var sampleSession: Double?

  init(configPath: String?) {
    self.configPath = configPath
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
      workers[id]?.cancel()
      tasks[id]?.cancel()
      operations[index].state = "cancelled"
      operations[index].message = "Cancelled"
      persist()
      return operations[index]
    }
    guard !operations.contains(where: { $0.state == "running" }) else {
      throw ValidationError("An operation is already running. Wait for it to finish.")
    }
    let operation = DesktopOperation(
      id: request.id, action: request.action, started_at: Date().timeIntervalSince1970,
      cancellable: ["download", "diagnose", "link"].contains(request.action))
    requests[request.id] = request
    operations.insert(operation, at: 0)
    operations = Array(operations.prefix(32))
    requests = requests.filter { key, _ in operations.contains { $0.id == key } }
    persist()
    tasks[request.id] = Task { await self.execute(request) }
    return operation
  }

  private func execute(_ request: DesktopAction) async {
    do {
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
      } else if request.action == "link" {
        guard AuthTokenStore.load() == nil else {
          throw ValidationError("This Mac is already linked")
        }
        let config = try loadRuntimeConfiguration(configPath: configPath).config
        _ = try await performDeviceCodeLogin(
          coordinatorURL: config.coordinator.url,
          onDisplayCode: { [weak self] code, url, seconds in
            Task {
              await self?.setLink(
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
          try await DesktopLocalLifecycle.stop()
        }
        let arguments = try arguments(for: request)
        let worker = DesktopWorker()
        workers[request.id] = worker
        let before = executableStamp()
        let (code, output) = try await worker.run(
          arguments,
          progress: { [weak self] output in
            Task { await self?.setProgress(request.id, output: output) }
          })
        complete(request.id, code: code, message: output)
        workers[request.id] = nil
        if request.action == "update", code == 0, executableStamp() != before {
          // launchd reopens the replacement CLI after the native updater commits it.
          Darwin.exit(0)
        }
      }
    } catch { complete(request.id, code: 1, message: String(describing: error)) }
    localAt = .distantPast
    tasks[request.id] = nil
  }

  func arguments(for request: DesktopAction) throws -> [String] {
    let config = configPath.map { ["--config", $0] } ?? []
    switch request.action {
    case "start":
      guard request.local != true else {
        return ["desktop", "start-local"] + (request.models ?? []).flatMap { ["--model", $0] }
          + config
      }
      return ["start"] + (request.models ?? []).flatMap { ["--model", $0] }
        + (request.endpoint == true ? ["--local-endpoint"] : []) + config
    case "switch":
      if DesktopLocalLifecycle.isActive {
        return ["desktop", "start-local"] + (request.models ?? []).flatMap { ["--model", $0] }
          + config
      }
      return ["switch"] + (request.models ?? []).flatMap { ["--model", $0] }
    case "stop", "restart":
      return DesktopLocalLifecycle.isActive
        ? ["desktop", request.action == "stop" ? "stop-local" : "restart-local"] : [request.action]
    case "update", "diagnose": return [request.action == "diagnose" ? "doctor" : "update"] + config
    case "unlink": return ["logout"]
    case "download": return ["models", "download", request.model!] + config
    case "remove":
      let state = DaemonStateFile.read()
      guard !(state?.warmModels.contains(request.model!) ?? false),
        !(state?.advertisedModels?.contains(request.model!) ?? false)
      else { throw ValidationError("Stop serving this model before removing it") }
      return ["models", "remove", request.model!, "--force"] + config
    case "cooling":
      return [
        "desktop", "configure-cooling", "--enabled", request.enabled == true ? "true" : "false",
        "--speed", String(request.speed ?? 70), "--temperature", String(request.temperature ?? 50),
      ]
    default: throw ValidationError("Unsupported action")
    }
  }

  private func setLink(_ value: JSONValue) { link = value }
  private func setProgress(_ id: String, output: String) {
    guard let index = operations.firstIndex(where: { $0.id == id }),
      operations[index].state == "running"
    else { return }
    operations[index].message = String(output.suffix(8000))
  }
  private func complete(_ id: String, code: Int32, message: String) {
    guard let index = operations.firstIndex(where: { $0.id == id }),
      operations[index].state == "running"
    else { return }
    operations[index].state = code == 0 ? "succeeded" : "failed"
    operations[index].finished_at = Date().timeIntervalSince1970
    operations[index].message = String(message.suffix(8000))
    persist()
  }
  private func persist() { try? DesktopStorage.write(operations, name: "operations.json") }
  private func executableStamp() -> String {
    guard let path = try? FanServiceManager().currentExecutableURL().path,
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    else { return "unknown" }
    return
      "\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(attributes[.modificationDate] ?? "")"
  }

}
