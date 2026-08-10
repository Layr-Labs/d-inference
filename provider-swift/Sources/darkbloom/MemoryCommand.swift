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
            try setLimit(
                rawValue: action[1], physicalGb: physicalGb, snapshot: snapshot,
                advertised: advertisedModels(from: snapshot.models, config: snapshot.config))

        default:
            printError("Unknown action: '\(action[0])'. Use 'status' or 'limit <GB>|none'.")
            throw ExitCode.failure
        }
    }

    // MARK: - limit set/clear

    private func setLimit(
        rawValue: String,
        physicalGb: UInt64,
        snapshot: RuntimeSnapshot,
        advertised: [ModelInfo]
    ) throws {
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
            var provider = snapshot.config.provider
            provider.memoryLimitGB = gb
            for line in Memory.fitWarnings(
                provider: provider, physicalGb: physicalGb, advertised: advertised)
            {
                printError(line)
            }
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

    /// Effective inference cap in bytes: the most conservative of the 90%
    /// unified-memory cap and `physical − effectiveReserve`. Mirrors the
    /// daemon's real gate.
    static func inferenceCapBytes(provider: ProviderSettings, physicalBytes: UInt64) -> UInt64 {
        let reserve = provider.effectiveReserveBytes(physicalBytes: physicalBytes)
        return min(
            UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes),
            physicalBytes > reserve ? physicalBytes - reserve : 0
        )
    }

    /// Operator warnings for a newly-set limit. Pure — testable without IO.
    ///
    /// A limit can be valid (≥ 8 GB, below physical) and still be too small to
    /// load anything this machine advertises. That state is worse than it
    /// looks: base rewards require a warm advertised model
    /// (`payments/baserewards/engine.go` gate 4 — `!p.Online || !p.ModelLoaded`
    /// skips the candidate), so a provider that can load nothing earns **$0**,
    /// not a reduced amount. Warn loudly rather than let the operator discover
    /// it from a zero payout a month later.
    static func fitWarnings(
        provider: ProviderSettings,
        physicalGb: UInt64,
        advertised: [ModelInfo]
    ) -> [String] {
        guard !advertised.isEmpty else { return [] }
        let physicalBytes = physicalGb * 1_073_741_824
        let cap = inferenceCapBytes(provider: provider, physicalBytes: physicalBytes)
        let headroom = UnifiedMemoryCap.loadHeadroomBytes()

        func fits(_ model: ModelInfo) -> Bool {
            let need = UInt64(max(0, model.estimatedMemoryGb) * 1_073_741_824)
            let (total, overflow) = need.addingReportingOverflow(headroom)
            return !overflow && total <= cap
        }

        let evicted = advertised.filter { !fits($0) }
        guard !evicted.isEmpty else { return [] }

        var lines = [
            "  WARNING: \(evicted.count) advertised model(s) no longer fit under this limit:"
        ]
        lines.append(contentsOf: evicted.map { "    - \($0.id) (~\(Int($0.estimatedMemoryGb.rounded())) GB)" })
        if evicted.count == advertised.count {
            lines.append("  NO advertised model fits — the provider will load nothing, serve nothing,")
            lines.append("  and earn NO base rewards (they require a warm model). Raise the limit or")
            lines.append("  download a smaller model before restarting.")
        }
        return lines
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
        let cap = inferenceCapBytes(provider: provider, physicalBytes: physicalBytes)

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
