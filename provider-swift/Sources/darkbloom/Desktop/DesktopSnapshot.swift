import Foundation
import ProviderCore

extension DesktopBackend {
  func state() async throws -> JSONValue {
    let loaded = try configuration()
    let now = Date()
    if now.timeIntervalSince(localAt) > 30 {
      ModelScanner.configureCacheDirectory(
        try ConfigManager.modelCacheDirectory(in: loaded.config, relativeTo: loaded.configPath))
      localModels = loaded.hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
      localAt = now
    }
    refreshCatalogIfNeeded(coordinator: loaded.config.coordinator.url, now: now)
    let daemon = DaemonStateFile.read()
    let current = daemon?.processIdentity?.isCurrent() == true
    let fresh = current && daemon?.isStale(now: now.timeIntervalSince1970) == false
    let resident = fresh ? daemon?.warmModels ?? [] : []
    let localEndpoint = LocalEndpoint.readLiveInfo()
    let localOnly = localEndpoint != nil && (!current || daemon?.pid != localEndpoint?.pid)
    let selected =
      localOnly
      ? LaunchAgent.installedLocalModels() ?? []
      : (fresh ? daemon?.advertisedModels ?? [] : loaded.config.backend.enabledModels)
    let phase =
      fresh
      ? (daemon?.lifecycle?.outcome == .draining ? "draining" : "running")
      : (current ? "stale" : (localEndpoint == nil ? "stopped" : "running"))
    let supported = Set(EngineV2SupportedModels.partition(localModels).supported.map(\.id))
    let capabilities = Set(
      (daemon?.runtimeCapabilities ?? []).map { ProviderRuntimeCapability(rawValue: $0) })
    let modelIDs = Set(catalog.map(\.id)).union(localModels.map(\.id)).sorted()
    let models = modelIDs.map { id -> JSONValue in
      let entry = catalog.first { $0.id == id }
      let local = localModels.first { $0.id == id }
      let runtimeOK =
        !fresh || daemon?.runtimeCapabilities == nil
        || ModelRuntimeRequirements.isEligible(modelID: id, available: capabilities)
      let reason: String? =
        local == nil
        ? nil
        : (!supported.contains(id)
          ? "Unsupported by this runtime"
          : (local?.templateRenderOK == false
            ? "Chat template validation failed"
            : (!runtimeOK ? "Runtime capability check required before serving" : nil)))
      return .dict([
        "id": .string(id), "display_name": .string(entry?.displayName ?? id),
        "size_gb": .number(entry?.sizeGb ?? local.map { Double($0.sizeBytes) / 1_073_741_824 }),
        "memory_gb": .number(local?.estimatedMemoryGb), "downloaded": .bool(local != nil),
        "serving": .bool(selected.contains(id)), "loaded": .bool(resident.contains(id)),
        "eligible": .bool(reason == nil), "reason": reason.map(DV.string) ?? .null,
        "description": entry?.description.map(DV.string) ?? .null,
        "context_length": .number(entry?.maxContextLength.map(Double.init)),
        "family": entry?.family.map(DV.string) ?? .null,
        "quantization": entry?.quantization.map(DV.string) ?? .null,
      ])
    }
    if fresh, sampleSession != daemon?.startedAt {
      sampleSession = daemon?.startedAt
      samples = []
    }
    let requestCount = fresh ? daemon?.stats.requestsServed ?? 0 : 0
    let tokens = fresh ? daemon?.stats.tokensGenerated ?? 0 : 0
    if fresh, samples.last?.field("at").number.map({ now.timeIntervalSince1970 - $0 >= 60 }) ?? true
    {
      samples.append(
        .dict([
          "at": .number(now.timeIntervalSince1970), "requests": .number(Double(requestCount)),
          "tokens": .number(Double(tokens)),
        ]))
      samples = Array(samples.suffix(1440))
    }
    let promptTokens = fresh ? daemon?.stats.promptTokensProcessed : nil
    let promptCount: JSONValue = promptTokens.map { JSONValue.string(String($0)) } ?? .null
    var activity: [String: JSONValue] = [
      "models": Self.modelActivity(daemon?.capacity, fresh: fresh, now: now.timeIntervalSince1970),
      "sampled_at": .number(fresh ? daemon?.capacity?.activityObservedAt : nil),
      "requests": fresh ? .string(String(requestCount)) : .null,
      "tokens": fresh ? .string(String(tokens)) : .null,
      "prompt_tokens": promptCount,
      "usage_gaps": fresh ? .string(String(daemon?.stats.usageGaps ?? 0)) : .null,
      "started_at": .number(fresh ? daemon?.startedAt : nil), "samples": .array(samples),
    ]
    activity.merge(sessionUsage(daemon: daemon, fresh: fresh, now: now)) { _, usage in usage }
    let total = Double(loaded.hardware?.memoryGb ?? 0)
    let machine: JSONValue = .dict([
      "id": .string("this-mac"), "name": .string(loaded.config.provider.name),
      "chip": .string(loaded.hardware?.chipName ?? "Unknown hardware"), "memory_gb": .number(total),
      "status": .string(phase), "version": .string(daemon?.version ?? ProviderCore.version),
      "models": .array(selected.map(DV.string)),
      "observed_at": .number(fresh ? daemon?.writtenAt : nil),
    ])
    return .dict([
      "protocol": .int(1), "version": .string(ProviderCore.version),
      "installation_id": .string(instance),
      "observed_at": .number(now.timeIntervalSince1970),
      "resource_revision": .string(String(Int(now.timeIntervalSince1970 / 30))),
      "linked": .bool(AuthTokenStore.load() != nil),
      "account_revision": .string(accountSession.observe("\(loaded.config.coordinator.url)\n\(accountReadToken() ?? "")")),
      "account": accountStatus(),
      "capabilities": .array(["account-signin", "account-signout", "request-history"].map(DV.string)),
      "state": .string(phase),
      "readiness": .string(
        fresh
          ? daemon?.trust?.reason ?? "Provider connected"
          : (current
            ? "Waiting for a fresh provider snapshot"
            : (localEndpoint == nil ? "Ready when you are" : "Local endpoint is listening"))),
      "machine": machine, "models": .array(models), "operations": try .encoded(operations),
      "memory": .dict([
        "total_gb": .number(total),
        "active_gb": .number(fresh ? daemon?.capacity?.gpuMemoryActiveGb : nil),
        "cache_gb": .number(fresh ? daemon?.capacity?.gpuMemoryCacheGb : nil),
        "free_for_load_gb": .number(fresh ? daemon?.capacity?.freeForLoadGb : nil),
      ]),
      "activity": .dict(activity),
      "settings": .dict([
        "revision": .string(DesktopStorage.revision(loaded.configPath)),
        "name": .string(loaded.config.provider.name),
        "auto_update": .bool(loaded.config.provider.autoUpdate),
        "idle_minutes": .number(Double(loaded.config.backend.idleTimeoutMins)),
        "cache_path": .string(ModelScanner.defaultCacheDirectory()?.path ?? ""),
        "schedule": (try? .encoded(loaded.config.schedule)) ?? .null,
        "startup_preload": .bool(loaded.config.backend.startupPreload),
      ]),
      "endpoint": localEndpoint.map {
        .dict([
          "base_url": .string($0.baseURL), "authenticated": .bool(!$0.apiKey.isEmpty),
          "models": .array(selected.map(DV.string)),
        ])
      } ?? .null,
      "link": link, "catalog_error": catalogError.map(DV.string) ?? .null,
    ])
  }

}
