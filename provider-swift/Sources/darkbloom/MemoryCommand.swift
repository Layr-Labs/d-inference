import ArgumentParser
import Foundation
import ProviderCore

struct Memory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Show or cap how much unified memory the provider may use.",
        discussion: """
        Sets `provider.memory_limit_gb` in the TOML config file: an absolute
        ceiling (GB) on the provider's total inference footprint (weights +
        KV cache + activations). The most conservative of the standard 90%
        unified-memory cap, `memory_reserve_gb`, and this limit wins.

        Examples:
          darkbloom memory              Show memory status
          darkbloom memory status       Same as above
          darkbloom memory limit 150    Cap the provider at 150 GB
          darkbloom memory limit none   Remove the cap
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Argument(parsing: .remaining, help: "Action: status | limit <GB>|none")
    var action: [String] = []

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let physicalGb = snapshot.hardware?.memoryGb ?? HardwareDetector.totalMemoryGB()

        switch action.first?.lowercased() {
        case nil, "status":
            for line in Memory.statusLines(
                provider: snapshot.config.provider,
                physicalGb: physicalGb,
                configDescription: describeConfigPath(snapshot)
            ) {
                print(line)
            }

        case "limit":
            guard action.count == 2 else {
                printError("usage: darkbloom memory limit <GB>|none")
                throw ExitCode.failure
            }
            try setLimit(rawValue: action[1], physicalGb: physicalGb, snapshot: snapshot)

        default:
            printError("Unknown action: '\(action[0])'. Use 'status' or 'limit <GB>|none'.")
            throw ExitCode.failure
        }
    }

    // MARK: - limit set/clear

    private func setLimit(rawValue: String, physicalGb: UInt64, snapshot: RuntimeSnapshot) throws {
        switch Memory.parseLimitArgument(rawValue, physicalGb: physicalGb) {
        case .invalid(let message):
            printError(message)
            throw ExitCode.failure
        case .clear:
            try writeLimit(nil, snapshot: snapshot)
            print("Memory limit removed — the standard 90% unified-memory cap applies.")
        case .set(let gb):
            try writeLimit(gb, snapshot: snapshot)
            print("Memory limit set to \(gb) GB (of \(physicalGb) GB physical).")
        }
        print("Restart the provider (darkbloom restart) to apply.")
    }

    private func writeLimit(_ value: UInt64?, snapshot: RuntimeSnapshot) throws {
        var config = snapshot.config
        if config.provider.memoryLimitGB == value && snapshot.configFileExists {
            // Already in the desired state — no-op.
            return
        }
        config.provider.memoryLimitGB = value
        try ConfigManager.save(config, to: snapshot.configPath)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Parsed operator input for `memory limit <value>` and `start --memory-limit`.
    enum LimitArgument: Equatable {
        case clear
        case set(UInt64)
        case invalid(String)
    }

    /// Shared validation for the memory-limit value: a whole number of GB
    /// that is ≥ 8 and strictly below this Mac's physical memory, or `none`
    /// to remove the limit. Pure — testable without IO or hardware.
    static func parseLimitArgument(_ raw: String, physicalGb: UInt64) -> LimitArgument {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" { return .clear }
        guard let gb = UInt64(value) else {
            return .invalid("Invalid memory limit '\(raw)': use a whole number of GB (e.g. 150) or 'none'.")
        }
        if gb < 8 {
            return .invalid("Memory limit must be at least 8 GB (got \(gb)).")
        }
        if gb >= physicalGb {
            return .invalid(
                "Memory limit of \(gb) GB is not below this Mac's \(physicalGb) GB of physical memory, "
                    + "so it would have no effect. Remove the limit with 'darkbloom memory limit none'.")
        }
        return .set(gb)
    }

    /// Pure renderer for the `memory` / `memory status` view. The inference
    /// cap mirrors the daemon's real gate: the most conservative of the 90%
    /// unified-memory cap and physical minus the effective reserve (which
    /// already folds `memory_limit_gb` in via `effectiveReserveBytes`).
    static func statusLines(
        provider: ProviderSettings,
        physicalGb: UInt64,
        configDescription: String
    ) -> [String] {
        let physicalBytes = physicalGb * 1_073_741_824
        let reserve = provider.effectiveReserveBytes(physicalBytes: physicalBytes)
        let cap = min(
            UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes),
            physicalBytes > reserve ? physicalBytes - reserve : 0
        )

        let limitLine: String
        if let limit = provider.memoryLimitBytes(physicalBytes: physicalBytes) {
            limitLine = "Memory limit: \(formatGb(limit)) GB"
        } else if let raw = provider.memoryLimitGB, raw > 0 {
            // Configured but not below physical — normalized away (no effect).
            limitLine = "Memory limit: none (configured \(raw) GB is not below physical — ignored)"
        } else {
            limitLine = "Memory limit: none"
        }

        return [
            "Physical memory: \(physicalGb) GB",
            limitLine,
            "Memory reserve: \(provider.memoryReserveGB) GB (memory_reserve_gb)",
            "Inference cap: \(formatGb(cap)) GB",
            "Config: \(configDescription)",
        ]
    }

    /// Bytes → GB string, whole numbers without a decimal ("150"), else one
    /// decimal ("230.4").
    private static func formatGb(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        return gb == gb.rounded() ? String(UInt64(gb)) : String(format: "%.1f", gb)
    }
}
