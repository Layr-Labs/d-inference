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
  /// This Mac's pair for the snapshot (`snapshotCapabilities`, `pairSnapshot`), read again after 30 s, since
  /// `ClusterPairSummary.local()` asks launchctl. An action reads it afresh (`arguments(for:)`).
  var pairAt = Date.distantPast
  var pair = ClusterPairSummary.notPaired
  var link: JSONValue = .null
  var samples: [JSONValue] = []
  var sampleSession: Double?
  var accountEarningsCache: (key: String, at: Date, value: JSONValue)?
  var accountEarningsTask: (key: String, task: Task<JSONValue, Error>)?
  var usageArchive = DesktopUsageArchive()
  var usageReadAt = Date.distantPast
  var usageRead: Task<Void, Never>?
  var accountSession = DesktopAccountSession()
  var accountIdentityRead: Task<Void, Never>?
  var accountIdentityReadAt = Date.distantPast
  /// Shared `fan status` read; `coolingReadAt` is nil while it is in flight.
  var coolingRead: Task<JSONValue, Never>?
  var coolingReadAt: Date?
  /// Profile of the child-operation runtime, keyed by its executable stamp.
  var runtimeProfileCache: (stamp: String, profile: DesktopRuntimeProfile)?
  /// On-demand reads of other commands (`cluster status`, `sandbox status`, waitlists), shared while fresh (`sharedRead`).
  var sharedReads: [String: DesktopSharedRead] = [:]
  /// Whether an account key is saved for the local router (`Snapshot.local.route_key`; `accountKeySaved`).
  var accountKeyRead: (at: Date, saved: Bool)?
  /// The guided cluster setup (`DesktopClusterSession.swift`); while it runs it holds the mutation slot.
  nonisolated let clusterSessions = DesktopClusterSessions()

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
    // Read only for a start that may start the pair (no models) or serve this Mac alone (`solo`).
    let pair = request.action == "start" && ((request.models ?? []).isEmpty || request.solo == true)
      ? ClusterPairSummary.local() : nil
    try request.validate(
      startsThePair: { try pair.map(Self.startsThePair) ?? false }, paired: { pair?.paired ?? false })
    // An account key is kept only as a digest, to recognize a retry with the same ID.
    let retained = request.retained(digest: Self.requestDigest)
    if let original = requests[request.id] {
      guard original == retained, let operation = operations.first(where: { $0.id == request.id })
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
    guard !clusterSessions.running else { throw ValidationError(DesktopClusterSessions.busyMessage) }
    let operation = DesktopOperation(
      id: request.id, action: request.action, started_at: Date().timeIntervalSince1970,
      cancellable: ["download", "diagnose", "link", "account-signin", "autopilot", "sandbox_setup"]
        .contains(request.action))
    requests[request.id] = retained
    operations.insert(operation, at: 0)
    operations = Array(operations.prefix(32))
    requests = requests.filter { key, _ in operations.contains { $0.id == key } }
    persist()
    tasks[request.id] = Task { await self.execute(request) }
    return operation
  }

  /// Whether a `start` that names no models starts this Mac's pair: the app's Start on a Mac in a two-Mac pair
  /// (`startPlan.startAction`), where `start` starts the pair with its own model (`Start.pairStart`). `paired` is `start`'s
  /// own test, so a pairing record that can't be read counts too, and `start` then refuses in its own words. Elsewhere
  /// such a start is refused as before ("Choose at least one model"). A pair with no model yet is refused at once with
  /// the CLI's one line for it, before anything runs, never "starting the pair".
  static func startsThePair(_ pair: ClusterPairSummary) throws -> Bool {
    guard pair.paired else { return false }
    if !pair.pairingUnreadable, pair.model == nil { throw ValidationError(pair.noModelLine) }
    return true
  }

  private func execute(_ request: DesktopAction) async {
    defer {
      workers[request.id] = nil
      tasks[request.id] = nil
      cancellationRequested.remove(request.id)
      localAt = .distantPast
      operationFinished(request.action)
      forgetSharedReads(after: request.action)
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
      } else if request.action == "waitlist_join" {
        await executeWaitlistJoin(request)
      } else if request.action == "local_settings" {
        try executeLocalSettings(request)
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
          },
          // The app shows the code first; the link page opens only when the user clicks.
          automaticallyOpenBrowser: false)
        link = .null
        complete(request.id, code: 0, message: "This Mac is linked to your account.")
      } else {
        if request.action == "start", request.local != true, DesktopLocalLifecycle.isActive {
          try await DesktopLocalLifecycle.stop(configPath: configPath)
        }
        let arguments = try arguments(for: request)
        try await requireRuntimeSupport(arguments)
        try Task.checkCancellation()
        let worker = request.action == "sandbox_setup"
          ? DesktopWorker(executable: executable, terminationGrace: Self.sandboxSetupGrace)
          : DesktopWorker(executable: executable)
        workers[request.id] = worker
        if request.action == "download" {
          setDownloadModel(request.id, model: request.model)
        }
        let before = Self.currentExecutableStamp()
        let (code, output) = try await runChild(request, arguments: arguments, worker: worker)
        complete(request.id, code: code, message: Self.withoutKey(output, request: request))
        if ["update", "update_rollback"].contains(request.action), code == 0,
          Self.shouldRestartForReplacedExecutable(
            startup: before, current: Self.currentExecutableStamp(), hasRunningOperation: false)
        {
          // launchd reopens the replacement CLI after the native updater commits it.
          Darwin.exit(0)
        }
      }
    } catch {
      if ["link", "account-signin"].contains(request.action) { link = .null }
      complete(request.id, code: 1, message: Self.withoutKey(String(describing: error), request: request))
    }
  }

  /// Runs a validated action's child on `worker`: Autopilot and Darkbloom Sandbox setup follow their child's output
  /// themselves; any other action reports what its child prints as its progress.
  private func runChild(_ request: DesktopAction, arguments: [String], worker: DesktopWorker) async throws
    -> (Int32, String)
  {
    switch request.action {
    case "autopilot":
      return try await runAutopilot(request, arguments: arguments, worker: worker, beforeStart: { [configPath] in
        if DesktopLocalLifecycle.isActive { try await DesktopLocalLifecycle.stop(configPath: configPath) }
      })
    case "sandbox_setup":
      return try await runSandboxSetup(request, arguments: arguments, worker: worker)
    default:
      // `route_key`'s key goes on standard input only (`routeKeyInput`); its output never holds it (`withoutKey`).
      return try await worker.run(arguments, input: Self.routeKeyInput(request), progress: { [weak self] output in
        Task { await self?.setProgress(request.id, output: Self.withoutKey(output, request: request)) }
      })
    }
  }

  func arguments(for request: DesktopAction) throws -> [String] {
    // First, so a refused Autopilot downloads nothing: `runAutopilot` downloads only after this. `paired` is the test
    // `start` makes (`Start.pairStart`), so a pairing record that can't be read counts too.
    if Self.pairRefusedActions.contains(request.action) {
      let pair = ClusterPairSummary.local()
      if pair.paired { throw ValidationError(Self.pairAutopilotRefusal(pair)) }
    }
    if request.action == "autopilot_pin" { try validateAutopilotPins(request.models ?? []) }
    if request.action == "autopilot_models" {
      let config = try configuration().config
      return try Self.autopilotRefreshArguments(settings: config.backend.modelAutopilot,
        startupModels: config.backend.enabledModels, endpoint: LocalEndpoint.readLiveInfo(), configPath: configPath)
    }
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
    if let arguments = autopilotArguments(for: request, config: config) { return arguments }
    switch request.action {
    case "start":
      // `--solo` only when asked (`solo`): otherwise, on a paired Mac this `start` starts the pair
      // (`Start.appStartOptions`) and local mode refuses (`Desktop.StartLocal.pairRefusal`). Alone, the mode is a flag of
      // `start --solo` itself, Only me (`--local`) included.
      if request.solo == true { return ["start", "--solo"] + models + servingFlag(request, local: "--local") + config }
      guard request.local != true else { return ["desktop", "start-local"] + models + config }
      return ["start"] + models + servingFlag(request, local: nil) + config
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
    case "cluster_leave": return ["cluster", "leave", "--yes"]
    case "sandbox_pause": return ["sandbox", "pause"]
    case "sandbox_resume": return ["sandbox", "resume"]
    case "sandbox_uninstall": return ["sandbox", "uninstall", "--yes"]
    case "sandbox_setup": return sandboxSetupArguments(request)
    case "route": return ["route", request.route!] + config
    case "route_key": return ["route", "key", "--stdin"] + config
    case "tool_setup": return ["start", "--\(request.tool!)"] + config
    case "update_rollback": return ["update", "--rollback", "--yes"] + config
    default: throw ValidationError("Unsupported action")
    }
  }

  /// The mode flag a start passes, saved in `[local] mode` (`LocalFirstOptions.savesModeFlag`): Both, me first
  /// (`endpoint`, `--local-endpoint`), the Darkbloom network (`network`, `--network`), or Only me where `start` takes it.
  static func servingFlag(_ request: DesktopAction, local: String?) -> [String] {
    if request.local == true, let local { return [local] }
    if request.endpoint == true { return ["--local-endpoint"] }
    return request.network == true ? ["--network"] : []
  }

  func setLink(_ id: String, _ value: JSONValue) {
    guard !cancellationRequested.contains(id),
      operations.contains(where: { $0.id == id && $0.state == "running" })
    else { return }
    link = value
  }
  func setProgress(_ id: String, output: String, downloadModel: String? = nil) {
    guard let index = operations.firstIndex(where: { $0.id == id }),
      operations[index].state == "running"
    else { return }
    if let downloadModel, operations[index].model != downloadModel { return }
    operations[index].message = String(output.suffix(8000))
    operations[index].progress = Self.downloadProgress(output)
  }
  func setDownloadModel(_ id: String, model: String?) {
    guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
    operations[index].model = model
    operations[index].progress = nil
    operations[index].message = model.map { "Downloading \($0)…" } ?? "Starting Autopilot…"
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
