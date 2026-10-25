import Foundation
import ProviderAppAttest

// A pre-update 0.9.15 watchdog may remain alive while the new daemon starts.
// Its decoder cannot read a non-nil `autopilot` field. Publish the detailed
// snapshot under a new additive key so that reader can still validate the
// heartbeat and promote the new version. New readers also accept old files.
// Keep schema 1: liveness, identity, lifecycle and all other fields are intact.
extension DaemonState {
    enum CodingKeys: String, CodingKey {
        case schema, pid, processIdentity, version, writtenAt
        case startedAt, attestationPublicKey, trust, runtimeIntegrity, coordinatorUrl, currentModel
        case warmModels, advertisedModels, startupPreloadPendingModels, lifecycle, modelSwitch
        case configPath, runtimeCapabilities, inferenceActive, requestWorkPending, loadTransitionActive
        case stats, system, capacity, lastModelLoadError, slots
        case connectivity, autopilot, autopilotPhase, autopilotOperation, appAttest
        case autopilotState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        pid = try c.decode(Int32.self, forKey: .pid)
        processIdentity = try c.decodeIfPresent(ProcessIdentity.self, forKey: .processIdentity)
        version = try c.decode(String.self, forKey: .version)
        writtenAt = try c.decode(Double.self, forKey: .writtenAt)
        startedAt = try c.decode(Double.self, forKey: .startedAt)
        attestationPublicKey = try c.decodeIfPresent(String.self, forKey: .attestationPublicKey)
        trust = try c.decodeIfPresent(Trust.self, forKey: .trust)
        runtimeIntegrity = try c.decodeIfPresent(RuntimeIntegrity.self, forKey: .runtimeIntegrity)
        coordinatorUrl = try c.decodeIfPresent(String.self, forKey: .coordinatorUrl)
        currentModel = try c.decodeIfPresent(String.self, forKey: .currentModel)
        warmModels = try c.decode([String].self, forKey: .warmModels)
        advertisedModels = try c.decodeIfPresent([String].self, forKey: .advertisedModels)
        startupPreloadPendingModels = try c.decodeIfPresent([String].self, forKey: .startupPreloadPendingModels)
        lifecycle = try c.decodeIfPresent(ProviderDrainStatus.self, forKey: .lifecycle)
        modelSwitch = try c.decodeIfPresent(ProviderModelSwitchStatus.self, forKey: .modelSwitch)
        configPath = try c.decodeIfPresent(String.self, forKey: .configPath)
        runtimeCapabilities = try c.decodeIfPresent([String].self, forKey: .runtimeCapabilities)
        inferenceActive = try c.decode(Bool.self, forKey: .inferenceActive)
        requestWorkPending = try c.decodeIfPresent(Bool.self, forKey: .requestWorkPending)
        loadTransitionActive = try c.decodeIfPresent(Bool.self, forKey: .loadTransitionActive)
        stats = try c.decode(Stats.self, forKey: .stats)
        system = try c.decodeIfPresent(SystemInfo.self, forKey: .system)
        capacity = try c.decodeIfPresent(Capacity.self, forKey: .capacity)
        lastModelLoadError = try c.decodeIfPresent(ModelLoadError.self, forKey: .lastModelLoadError)
        slots = try c.decodeIfPresent([SlotPosture].self, forKey: .slots)
        connectivity = try c.decodeIfPresent(Connectivity.self, forKey: .connectivity)
        autopilot = try c.decodeIfPresent(ModelAutopilotSnapshot.self, forKey: .autopilotState)
            ?? c.decodeIfPresent(ModelAutopilotSnapshot.self, forKey: .autopilot)
        autopilotPhase = try c.decodeIfPresent(String.self, forKey: .autopilotPhase)
        autopilotOperation = try c.decodeIfPresent(AutopilotOperation.self, forKey: .autopilotOperation)
        appAttest = try c.decodeIfPresent(AppAttestLocalStatus.self, forKey: .appAttest)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(pid, forKey: .pid)
        try c.encodeIfPresent(processIdentity, forKey: .processIdentity)
        try c.encode(version, forKey: .version)
        try c.encode(writtenAt, forKey: .writtenAt)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(attestationPublicKey, forKey: .attestationPublicKey)
        try c.encodeIfPresent(trust, forKey: .trust)
        try c.encodeIfPresent(runtimeIntegrity, forKey: .runtimeIntegrity)
        try c.encodeIfPresent(coordinatorUrl, forKey: .coordinatorUrl)
        try c.encodeIfPresent(currentModel, forKey: .currentModel)
        try c.encode(warmModels, forKey: .warmModels)
        try c.encodeIfPresent(advertisedModels, forKey: .advertisedModels)
        try c.encodeIfPresent(startupPreloadPendingModels, forKey: .startupPreloadPendingModels)
        try c.encodeIfPresent(lifecycle, forKey: .lifecycle)
        try c.encodeIfPresent(modelSwitch, forKey: .modelSwitch)
        try c.encodeIfPresent(configPath, forKey: .configPath)
        try c.encodeIfPresent(runtimeCapabilities, forKey: .runtimeCapabilities)
        try c.encode(inferenceActive, forKey: .inferenceActive)
        try c.encodeIfPresent(requestWorkPending, forKey: .requestWorkPending)
        try c.encodeIfPresent(loadTransitionActive, forKey: .loadTransitionActive)
        try c.encode(stats, forKey: .stats)
        try c.encodeIfPresent(system, forKey: .system)
        try c.encodeIfPresent(capacity, forKey: .capacity)
        try c.encodeIfPresent(lastModelLoadError, forKey: .lastModelLoadError)
        try c.encodeIfPresent(slots, forKey: .slots)
        try c.encodeIfPresent(connectivity, forKey: .connectivity)
        try c.encodeIfPresent(autopilot, forKey: .autopilotState)
        try c.encodeIfPresent(autopilotPhase, forKey: .autopilotPhase)
        try c.encodeIfPresent(autopilotOperation, forKey: .autopilotOperation)
        try c.encodeIfPresent(appAttest, forKey: .appAttest)
    }
}
