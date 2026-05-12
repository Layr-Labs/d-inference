import ArgumentParser
import ProviderCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show local provider configuration and hardware status."
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        // Best-effort: tell the user if a newer release is published before
        // we dump current status. Bounded by a 2s timeout in UpdateBanner.
        await runUpdateBannerIfEnabled()

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let config = snapshot.config
        let models = advertisedModels(from: snapshot.models, config: config)

        print("darkbloom \(ProviderCore.version)")
        print("Provider: \(config.provider.name)")
        print("Config: \(describeConfigPath(snapshot))")
        print("Coordinator: \(config.coordinator.url)")
        print("Backend port: \(config.backend.port)")
        print("Configured model: \(config.backend.model ?? "auto-select")")
        print("Continuous batching: \(config.backend.continuousBatching ? "enabled" : "disabled")")
        print("Idle timeout: \(config.backend.idleTimeoutMins == 0 ? "disabled" : "\(config.backend.idleTimeoutMins)m")")

        if let hardware = snapshot.hardware {
            print("Hardware: \(hardware.chipName), \(hardware.memoryGb) GB RAM, \(hardware.gpuCores) GPU cores")
            print("Inference memory: \(hardware.memoryAvailableGb) GB available")
        } else {
            print("Hardware: unavailable (\(snapshot.hardwareError?.localizedDescription ?? "unknown error"))")
        }

        if let scheduleConfig = config.schedule,
           let schedule = Schedule.from(config: scheduleConfig) {
            let active = schedule.isActiveNow()
            print("Schedule: \(schedule.describe())")
            print("Availability: \(active ? "active" : "inactive")")
        } else {
            print("Schedule: always available")
        }

        let enabledFilter = config.backend.enabledModels.isEmpty ? "none" : config.backend.enabledModels.joined(separator: ", ")
        print("Enabled model filter: \(enabledFilter)")
        print("Local MLX models: \(models.count)")
        print("Process control: not available yet in the Swift CLI")
    }
}
