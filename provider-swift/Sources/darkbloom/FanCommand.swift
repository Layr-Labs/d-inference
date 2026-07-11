import ArgumentParser
import Foundation
import ProviderCore

struct Fan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fan",
        abstract: "Boost cooling during hot inference requests.",
        discussion: """
        Runs a foreground, root-only cooling controller. It watches the local
        provider's live request state and boosts every fan only while inference
        is active and the hottest readable sensor is at or above the threshold.
        Press Ctrl-C to return fan control to macOS.

        Apple does not provide a supported fan-control API. This command uses
        the undocumented AppleSMC interface and is optional.
        """
    )

    @Option(
        name: .long,
        help: "Fan speed as a percentage of each fan's maximum RPM (default: 90)."
    )
    var speed = FanCoolingConfiguration.defaultSpeedPercent

    @Option(
        name: .long,
        help: "Temperature that activates cooling, in Celsius (default: 40)."
    )
    var temperature = FanCoolingConfiguration.defaultTriggerTemperatureCelsius

    @Option(
        name: .long,
        help: "Provider and sensor polling interval in seconds (default: 2)."
    )
    var pollInterval = FanCoolingConfiguration.defaultPollIntervalSeconds

    @Option(
        name: .long,
        help: "Provider daemon-state path (normally inferred through sudo)."
    )
    var stateFile: String?

    @Flag(
        name: .long,
        help: "Return all fans to macOS automatic control, then exit."
    )
    var reset = false

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        print("Warning: fan control uses Apple's undocumented AppleSMC interface.")
        if reset {
            try FanCoolingRunner.resetToAutomatic()
            print("All fans returned to macOS automatic control.")
            return
        }

        let configuration: FanCoolingConfiguration
        do {
            configuration = try FanCoolingConfiguration(
                speedPercent: speed,
                triggerTemperatureCelsius: temperature,
                pollIntervalSeconds: pollInterval
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        let stateURL = Self.resolveStateFile(
            explicitPath: stateFile
        )
        let monitor = FanTerminationMonitor()
        let runner = try FanCoolingRunner(
            configuration: configuration,
            stateFile: stateURL
        )
        try runner.run(
            shouldStop: { monitor.isTerminationRequested },
            wait: { monitor.wait(for: $0) },
            onEvent: Self.printEvent
        )
    }

    static func resolveStateFile(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        homeForUser: (String) -> URL? = {
            FileManager.default.homeDirectory(forUser: $0)
        }
    ) -> URL {
        let invokingUser = environment["SUDO_USER"].flatMap {
            $0.isEmpty || $0 == "root" ? nil : $0
        }
        let providerHome = invokingUser.flatMap(homeForUser) ?? currentHome
        let rawPath = explicitPath
            ?? environment["DARKBLOOM_STATE_FILE"]

        guard let rawPath, !rawPath.isEmpty else {
            return providerHome
                .appendingPathComponent(".darkbloom")
                .appendingPathComponent("daemon-state.json")
        }
        if rawPath == "~" {
            return providerHome
        }
        if rawPath.hasPrefix("~/") {
            return providerHome.appendingPathComponent(
                String(rawPath.dropFirst(2))
            )
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL
    }

    private static func printEvent(_ event: FanCoolingEvent) {
        switch event {
        case .ready(let summary):
            print("Watching provider activity: \(summary.stateFile.path)")
            print("Temperature sensors: \(summary.temperatureSensorCount)")
            for fan in summary.fans {
                print(
                    "Fan \(fan.index): \(fan.minimumRPM)-\(fan.maximumRPM) RPM, "
                        + "boost target \(fan.plannedRPM) RPM"
                )
            }
            print("Press Ctrl-C to stop and restore automatic fan control.")
        case .boosted(let sample, let targets):
            let temperature = formatTemperature(sample)
            print(
                "Inference hot (\(temperature)); boosting fans to "
                    + targets.map(String.init).joined(separator: "/")
                    + " RPM."
            )
        case .released(let reason, let sample):
            print(
                "\(releaseMessage(reason)) "
                    + "macOS automatic fan control restored"
                    + temperatureSuffix(sample)
                    + "."
            )
        case .warning(let message):
            printError("Warning: \(message)")
        case .restored:
            print("macOS automatic fan control restored.")
        }
    }

    private static func releaseMessage(
        _ reason: FanCoolingReleaseReason
    ) -> String {
        switch reason {
        case .providerIdle:
            return "Inference is idle;"
        case .cooled:
            return "Machine cooled below the release threshold;"
        case .temperatureUnavailable:
            return "Temperature became unavailable;"
        case .systemThermalPressure:
            return "macOS reported elevated thermal pressure;"
        case .stopped:
            return "Fan controller stopped;"
        }
    }

    private static func formatTemperature(_ sample: FanCoolingSample) -> String {
        guard let temperature = sample.hottestTemperatureCelsius else {
            return "temperature unavailable"
        }
        let sensor = sample.hottestSensor.map { " \($0)" } ?? ""
        return String(format: "%.1f°C%@", temperature, sensor)
    }

    private static func temperatureSuffix(_ sample: FanCoolingSample) -> String {
        guard sample.hottestTemperatureCelsius != nil else {
            return ""
        }
        return " at \(formatTemperature(sample))"
    }
}
