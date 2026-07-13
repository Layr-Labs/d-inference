import ArgumentParser
import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import ProviderCore

struct Fan: AsyncParsableCommand {
    static let packagedCapability = "darkbloom-fan-helper-v1"
    private static var commandTypes: [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [
            Status.self, Diagnose.self, Enable.self, Configure.self,
            Disable.self, Uninstall.self,
        ]
        #if DEBUG
        commands.append(TestLease.self)
        #endif
        return commands
    }

    static let configuration = CommandConfiguration(
        commandName: "fan",
        abstract: "Experimental temperature-based fan control for providers.",
        discussion: """
        Fan control is disabled by default. Enabling it installs a narrowly
        scoped root helper; manual fan targets are applied only while a signed
        Darkbloom provider is active and a validated GPU sensor is hot enough.
        """,
        subcommands: commandTypes,
        defaultSubcommand: Status.self
    )
}

extension Fan {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show fan hardware, policy, and helper state."
        )

        @Flag(help: "Emit JSON instead of text.")
        var json = false

        mutating func run() async throws {
            let manager = FanServiceManager()
            let diagnostic = Self.diagnosticReport()
            let loaded = manager.isLoaded()
            let helper: FanServiceStatus?
            let helperError: String?
            if loaded {
                do {
                    helper = try FanHelperClient().status()
                    helperError = nil
                } catch {
                    helper = nil
                    helperError = String(describing: error)
                }
            } else {
                helper = nil
                helperError = nil
            }
            let report = FanStatusReport(
                capability: Fan.packagedCapability,
                installed: manager.isInstalled(),
                loaded: loaded,
                helper: helper,
                helperError: helperError,
                diagnostic: diagnostic
            )
            if json {
                try printJSON(report)
                return
            }
            Self.print(report)
        }

        static func diagnosticReport() -> FanDiagnosticReport {
            do {
                let backend = try AppleSMCBackend()
                let reader = FanHardwareReader(backend: backend)
                let inventory = try reader.discover()
                let fans = try reader.fanReadings(in: inventory)
                let temperatures = try reader.gpuTemperatures(in: inventory)
                return FanDiagnosticReport(
                    chip: inventory.chipFamily.rawValue,
                    supported: !inventory.fans.isEmpty && !inventory.gpuTemperatureKeys.isEmpty,
                    gpuTemperatures: temperatures.map {
                        FanTemperatureStatus(key: $0.key.rawValue, celsius: $0.celsius)
                    },
                    fans: fans.map(Self.fanStatus),
                    error: nil
                )
            } catch {
                return FanDiagnosticReport(
                    chip: "Unknown",
                    supported: false,
                    gpuTemperatures: [],
                    fans: [],
                    error: String(describing: error)
                )
            }
        }

        static func fanStatus(_ reading: FanReading) -> FanServiceFanStatus {
            FanServiceFanStatus(
                index: reading.capability.index,
                actualRPM: reading.actualRPM,
                targetRPM: reading.targetRPM,
                minimumRPM: reading.minimumRPM,
                maximumRPM: reading.maximumRPM,
                mode: describe(reading.mode)
            )
        }

        static func describe(_ mode: FanMode) -> String {
            switch mode {
            case .automatic: return "auto"
            case .manual: return "manual"
            case .system: return "system"
            case .unknown(let raw): return "unknown(\(raw))"
            }
        }

        static func print(_ report: FanStatusReport) {
            Swift.print("Darkbloom fan control (experimental)")
            Swift.print("Installed: \(report.installed ? "yes" : "no")")
            Swift.print("Service: \(report.loaded ? "running" : "stopped")")
            if let helper = report.helper {
                Swift.print("Mode: \(helper.mode.rawValue)")
                Swift.print("Provider active: \(helper.providerActive ? "yes" : "no")")
                Swift.print(
                    "Policy: \(format(helper.speedPercent))% at \(format(helper.triggerTemperatureC)) C "
                        + "(release below \(format(helper.releaseTemperatureC)) C)"
                )
                if let temperature = helper.gpuTemperatureC {
                    Swift.print("GPU: \(format(temperature)) C")
                }
                if let error = helper.lastError {
                    Swift.print("Last error: \(error)")
                }
            } else {
                Swift.print(
                    report.loaded
                        ? "Mode: unknown (helper status unavailable)"
                        : "Mode: macOS automatic"
                )
                if let helperError = report.helperError {
                    Swift.print("Helper error: \(helperError)")
                }
            }

            Swift.print("Hardware: \(report.diagnostic.chip)")
            if let error = report.diagnostic.error {
                Swift.print("Compatibility: unavailable (\(error))")
            } else {
                Swift.print("Compatibility: \(report.diagnostic.supported ? "supported" : "unsupported")")
            }
            for fan in report.diagnostic.fans {
                Swift.print(
                    "  Fan \(fan.index): actual \(rpm(fan.actualRPM)), target \(rpm(fan.targetRPM)), "
                        + "range \(rpm(fan.minimumRPM))-\(rpm(fan.maximumRPM)), \(fan.mode ?? "unknown")"
                )
            }
            if !report.diagnostic.gpuTemperatures.isEmpty {
                let sensors = report.diagnostic.gpuTemperatures.map {
                    "\($0.key)=\(format($0.celsius)) C"
                }.joined(separator: ", ")
                Swift.print("GPU sensors: \(sensors)")
            }
            if !report.installed {
                Swift.print("Enable with: sudo darkbloom fan enable")
            }
        }

        private static func rpm(_ value: Double?) -> String {
            value.map { String(format: "%.0f", $0) } ?? "n/a"
        }

        private static func format(_ value: Double) -> String {
            String(format: "%.1f", value)
        }
    }

    struct Diagnose: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only fan and GPU-sensor compatibility report."
        )

        @Flag(help: "Emit JSON instead of text.")
        var json = false

        mutating func run() async throws {
            let report = Status.diagnosticReport()
            if json {
                try printJSON(report)
            } else {
                Status.print(FanStatusReport(
                    capability: Fan.packagedCapability,
                    installed: FanServiceManager().isInstalled(),
                    loaded: FanServiceManager().isLoaded(),
                    helper: nil,
                    helperError: nil,
                    diagnostic: report
                ))
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install and enable the opt-in root fan helper."
        )

        @Option(help: "Fan speed as percent of each fan's maximum (60-90).")
        var speed: Double = 80

        @Option(help: "GPU temperature in Celsius that engages fan control.")
        var temperature: Double = 45

        mutating func run() async throws {
            try runMutation {
                let status = try FanServiceManager().enable(
                    policy: try makePolicy(speed: speed, temperature: temperature)
                )
                Swift.print("Experimental fan control ENABLED.")
                Swift.print(
                    "  \(String(format: "%.0f", status.speedPercent))% at "
                        + "\(String(format: "%.0f", status.triggerTemperatureC)) C"
                )
                Swift.print("  Active only while the Darkbloom provider is running.")
                Swift.print("  Disable with: sudo darkbloom fan disable")
            }
        }
    }

    struct Configure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change the enabled fan policy."
        )

        @Option(help: "Fan speed as percent of each fan's maximum (60-90).")
        var speed: Double?

        @Option(help: "GPU temperature in Celsius that engages fan control.")
        var temperature: Double?

        mutating func run() async throws {
            guard speed != nil || temperature != nil else {
                throw ValidationError("provide --speed, --temperature, or both")
            }
            try runMutation {
                let manager = FanServiceManager()
                let current = try manager.configuration()
                let updated = try makePolicy(
                    speed: speed ?? current.policy.speedPercent,
                    temperature: temperature ?? current.policy.triggerCelsius
                )
                try manager.configure(policy: updated)
                Swift.print("Fan policy updated: \(updated.speedPercent)% at \(updated.triggerCelsius) C.")
            }
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore macOS automatic control and disable the helper."
        )

        mutating func run() async throws {
            try runMutation {
                try FanServiceManager().disable()
                Swift.print("Fan control disabled; macOS automatic control restored.")
            }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore macOS automatic control and remove the helper."
        )

        mutating func run() async throws {
            try runMutation {
                try FanServiceManager().uninstall()
                Swift.print("Fan helper uninstalled; macOS automatic control restored.")
            }
        }
    }

    #if DEBUG
    struct TestLease: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "test-lease",
            abstract: "Internal: hold a provider activity lease for hardware tests.",
            shouldDisplay: false
        )

        @Option(help: "Lease duration in seconds (1-300).")
        var seconds: Int = 30

        mutating func run() async throws {
            guard (1...300).contains(seconds) else {
                throw ValidationError("--seconds must be between 1 and 300")
            }
            try await withFanActivityLease(providerVersion: ProviderCore.version) {
                try await Task.sleep(
                    nanoseconds: UInt64(seconds) * 1_000_000_000
                )
            }
        }
    }
    #endif
}

private func makePolicy(speed: Double, temperature: Double) throws -> FanPolicyConfiguration {
    try FanPolicyConfiguration(
        triggerCelsius: temperature,
        releaseCelsius: temperature - 5,
        speedPercent: speed
    )
}

private func runMutation(_ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        printError("fan: \(error)")
        throw ExitCode.failure
    }
}

struct FanStatusReport: Encodable {
    let capability: String
    let installed: Bool
    let loaded: Bool
    let helper: FanServiceStatus?
    let helperError: String?
    let diagnostic: FanDiagnosticReport
}

struct FanDiagnosticReport: Encodable {
    let chip: String
    let supported: Bool
    let gpuTemperatures: [FanTemperatureStatus]
    let fans: [FanServiceFanStatus]
    let error: String?
}

struct FanTemperatureStatus: Encodable {
    let key: String
    let celsius: Double
}
