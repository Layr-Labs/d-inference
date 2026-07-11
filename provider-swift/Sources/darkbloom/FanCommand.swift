import ArgumentParser
import FanControlCore
import Foundation
import ProviderCore

struct Fan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fan",
        abstract: "Boost cooling during hot inference requests.",
        discussion: """
        Runs a foreground cooling client. A separately installed, signed helper
        performs the privileged fan writes and restores macOS control if this
        client exits or stops renewing its short lease.

        Apple does not provide a supported fan-control API. This optional
        command uses the undocumented AppleSMC interface.
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
        help: "Provider and helper polling interval in seconds (default: 2)."
    )
    var pollInterval = FanCoolingConfiguration.defaultPollIntervalSeconds

    @Option(
        name: .long,
        help: "Provider activity path (default: ~/.darkbloom/inference-activity.json)."
    )
    var activityFile: String?

    @Flag(
        name: .long,
        help: "Install the signed privileged helper with an admin prompt, then exit."
    )
    var installHelper = false

    @Flag(
        name: .long,
        help: "Return all fans to macOS automatic control, then exit."
    )
    var reset = false

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        guard !(installHelper && reset) else {
            throw ValidationError(
                "--install-helper and --reset cannot be used together"
            )
        }

        if installHelper {
            try FanHelperInstaller.install()
            print(
                "Installed the signed Darkbloom fan helper. "
                    + "Run `darkbloom fan` to start cooling."
            )
            return
        }

        let cooling: FanCoolingConfiguration
        do {
            cooling = try FanCoolingConfiguration(
                speedPercent: speed,
                triggerTemperatureCelsius: temperature,
                pollIntervalSeconds: pollInterval
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        let client = FanHelperClient()
        do {
            try client.verifyProtocol()
        } catch {
            throw ValidationError(
                "\(error.localizedDescription). Install it with "
                    + "`darkbloom fan --install-helper`."
            )
        }

        if reset {
            try client.restoreAutomatic()
            print("All fans returned to macOS automatic control.")
            return
        }

        let stateURL = Self.resolveActivityFile(
            explicitPath: activityFile
        )
        let activity = FanProviderActivityReader(
            stateFile: stateURL,
            maximumStateAge: max(15, pollInterval * 3)
        )
        let monitor = FanTerminationMonitor()
        let lease = try client.acquireLease(
            speedPercent: cooling.speedPercent,
            triggerTemperatureCelsius:
                cooling.triggerTemperatureCelsius
        )

        print("Warning: fan control uses Apple's undocumented AppleSMC interface.")
        print("Watching provider activity: \(stateURL.path)")
        print(
            "Boost policy: \(Int(cooling.speedPercent))% at "
                + "\(String(format: "%.1f", cooling.triggerTemperatureCelsius))°C."
        )
        print("Press Ctrl-C to stop; the helper lease restores macOS control.")

        var sequence: UInt64 = 0
        var previouslyEngaged = false
        var operationError: Error?
        do {
            while !monitor.isTerminationRequested {
                sequence &+= 1
                let status = try client.renewLease(
                    lease,
                    sequence: sequence,
                    inferenceActive: activity.inferenceActive()
                )
                Self.printTransition(
                    status,
                    previouslyEngaged: previouslyEngaged
                )
                previouslyEngaged = status.engaged
                if monitor.wait(for: cooling.pollIntervalSeconds) {
                    break
                }
            }
        } catch {
            operationError = error
        }

        do {
            try client.releaseLease(lease)
            if previouslyEngaged {
                print("macOS automatic fan control restored.")
            }
        } catch let releaseError {
            if let operationError {
                throw ValidationError(
                    "\(operationError.localizedDescription); helper release "
                        + "also failed: \(releaseError.localizedDescription)"
                )
            }
            throw releaseError
        }
        if let operationError {
            throw operationError
        }
    }

    static func resolveActivityFile(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let rawPath = explicitPath
            ?? environment["DARKBLOOM_INFERENCE_ACTIVITY_FILE"]
        guard let rawPath, !rawPath.isEmpty else {
            return currentHome
                .appendingPathComponent(".darkbloom")
                .appendingPathComponent("inference-activity.json")
        }
        if rawPath == "~" {
            return currentHome
        }
        if rawPath.hasPrefix("~/") {
            return currentHome.appendingPathComponent(
                String(rawPath.dropFirst(2))
            )
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL
    }

    private static func printTransition(
        _ status: FanHelperStatus,
        previouslyEngaged: Bool
    ) {
        guard status.engaged != previouslyEngaged else { return }
        let temperature = status.temperatureCelsius.map {
            String(format: "%.1f°C", $0)
        } ?? "temperature unavailable"
        if status.engaged {
            let targets = status.targetRPMs.map { " at \($0) RPM" } ?? ""
            print("Inference hot (\(temperature)); fan boost engaged\(targets).")
        } else {
            print("Cooling boost released at \(temperature); macOS control restored.")
        }
    }
}
