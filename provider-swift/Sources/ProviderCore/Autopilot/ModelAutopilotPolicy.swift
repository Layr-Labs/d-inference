import Foundation

/// Pure, fail-closed validation before the runtime reserves the transition.
/// Runtime repeats this against live state after its memory-sampling await.
public enum ModelAutopilotPolicy {
    public static func rejection(command: ModelAutopilotCommand, snapshot: ModelAutopilotSnapshot,
                                 busy: Bool, nowMs: Int64) -> String? {
        guard snapshot.enabled, snapshot.protocolVersion == 1, snapshot.cachedOnly else { return "not_opted_in" }
        guard !command.commandId.isEmpty, command.commandId.utf8.count <= 64,
              command.unloadModelIds.count <= 32,
              command.expectedResidentModels.count <= 32,
              Set(command.unloadModelIds).count == command.unloadModelIds.count,
              Set(command.expectedResidentModels).count == command.expectedResidentModels.count,
              command.loadModelId?.isEmpty != true,
              command.loadModelId != nil || !command.unloadModelIds.isEmpty,
              command.leaseSeconds >= 0, command.leaseSeconds <= 86_400,
              !command.unloadModelIds.contains(where: { $0.isEmpty }),
              !(command.loadModelId.map { command.unloadModelIds.contains($0) } ?? false)
        else { return "invalid_command" }
        guard command.expiresAtMs > nowMs,
              command.expiresAtMs <= nowMs.addingReportingOverflow(300_000).partialValue
        else { return "expired_command" }
        guard !busy else { return "provider_busy" }
        let residents = Set(snapshot.residentModels.map(\.modelId))
        guard residents == Set(command.expectedResidentModels),
              Set(command.unloadModelIds).isSubset(of: residents)
        else { return "residency_changed" }
        guard Set(snapshot.pinnedModels).isDisjoint(with: command.unloadModelIds) else { return "pinned_model" }
        for victim in snapshot.residentModels where command.unloadModelIds.contains(victim.modelId) {
            guard victim.residentSeconds >= snapshot.minDwellSeconds,
                  victim.idleSeconds >= snapshot.minDwellSeconds else { return "minimum_dwell" }
        }
        let added = command.loadModelId.map { residents.contains($0) ? 0 : 1 } ?? 0
        guard residents.count - command.unloadModelIds.count + added <= snapshot.maxModelSlots else { return "slot_capacity" }
        return nil
    }
}
