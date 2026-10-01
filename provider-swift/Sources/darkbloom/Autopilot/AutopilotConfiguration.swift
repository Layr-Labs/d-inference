import ArgumentParser
import Foundation
import ProviderCore

func changeAutopilotPolicy(configPath: String?, change: (inout ModelAutopilotSettings) throws -> Void) throws {
    try withMutableConfig(configPath: configPath) { path, config in
        guard config.backend.modelAutopilot.hasConsent else { throw ValidationError("Enable Autopilot and select models first: darkbloom autopilot enable") }
        try change(&config.backend.modelAutopilot)
        config.backend.modelAutopilot.revision = UUID().uuidString
        try ConfigManager.save(config, to: path)
    }
}

@discardableResult
func setModelAutopilot(enabled: Bool, dwell: UInt64? = nil, pins: [String]? = nil,
                       configPath: String?) throws -> URL {
    if let dwell, !(60...86_400).contains(dwell) { throw ValidationError("min-dwell-seconds must be between 60 and 86400") }
    return try withMutableConfig(configPath: configPath) { path, config in
        var settings = config.backend.modelAutopilot
        if enabled && settings.selectedModels.isEmpty { settings.selectedModels = config.backend.enabledModels }
        if enabled { settings.selectedModels = try validatedAutopilotSelection(settings.selectedModels) }
        if let pins {
            guard Set(pins).isSubset(of: Set(settings.selectedModels)) else { throw ValidationError("Pins must be selected models.") }
            settings.pinnedModels = Array(Set(pins)).sorted()
        }
        settings.enabled = enabled; settings.consentRecorded = true; settings.paused = false
        settings.revision = UUID().uuidString
        if let dwell { settings.minDwellSeconds = dwell }
        config.backend.modelAutopilot = settings
        try ConfigManager.save(config, to: path)
        return path
    }
}
