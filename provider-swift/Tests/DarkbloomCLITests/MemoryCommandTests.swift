import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Unit tests for the `darkbloom memory` surface: the shared limit-argument
/// validator (also used by `start --memory-limit`), the TOML round-trip of
/// `memory_limit_gb` through ConfigManager, the pure status renderer, and the
/// `status` total-memory line.
@Suite("Memory limit CLI")
struct MemoryCommandTests {

    // MARK: - parseLimitArgument (shared validation)

    @Test("a valid limit below physical is accepted")
    func acceptsValidLimit() {
        #expect(Memory.parseLimitArgument("150", physicalGb: 256) == .set(150))
        // Boundaries: the 8 GB minimum itself and one below physical.
        #expect(Memory.parseLimitArgument("8", physicalGb: 256) == .set(8))
        #expect(Memory.parseLimitArgument("255", physicalGb: 256) == .set(255))
        #expect(Memory.parseLimitArgument(" 150 ", physicalGb: 256) == .set(150))
    }

    @Test("'none' clears the limit, case-insensitively")
    func noneClears() {
        #expect(Memory.parseLimitArgument("none", physicalGb: 256) == .clear)
        #expect(Memory.parseLimitArgument("NONE", physicalGb: 256) == .clear)
    }

    @Test("limits below 8 GB are rejected")
    func rejectsBelowMinimum() {
        guard case .invalid(let message) = Memory.parseLimitArgument("4", physicalGb: 256) else {
            Issue.record("expected .invalid for a 4 GB limit")
            return
        }
        #expect(message.contains("at least 8 GB"))
    }

    @Test("a limit at or above physical is rejected and points to 'memory limit none'")
    func rejectsAtOrAbovePhysical() {
        for raw in ["256", "300"] {
            guard case .invalid(let message) = Memory.parseLimitArgument(raw, physicalGb: 256) else {
                Issue.record("expected .invalid for \(raw) GB on a 256 GB box")
                return
            }
            #expect(message.contains("darkbloom memory limit none"))
        }
    }

    @Test("non-integer values are rejected")
    func rejectsNonInteger() {
        for raw in ["abc", "12.5", "", "-8"] {
            guard case .invalid = Memory.parseLimitArgument(raw, physicalGb: 256) else {
                Issue.record("expected .invalid for '\(raw)'")
                return
            }
        }
    }

    // MARK: - Config round-trip (memory_limit_gb in TOML)

    @Test("setting the limit writes memory_limit_gb; clearing removes the key")
    func limitRoundTripsThroughConfigFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("provider.toml")

        var config = ProviderConfig(provider: ProviderSettings(name: "test"))
        config.provider.memoryLimitGB = 150
        try ConfigManager.save(config, to: path)

        let savedText = try String(contentsOf: path, encoding: .utf8)
        #expect(savedText.contains("memory_limit_gb"))
        #expect(try ConfigManager.load(from: path).provider.memoryLimitGB == 150)

        // `memory limit none` → nil → the key disappears from the file and
        // loads back as "no limit".
        config.provider.memoryLimitGB = nil
        try ConfigManager.save(config, to: path)
        let clearedText = try String(contentsOf: path, encoding: .utf8)
        #expect(!clearedText.contains("memory_limit_gb"))
        #expect(try ConfigManager.load(from: path).provider.memoryLimitGB == nil)
    }

    // MARK: - Status rendering

    @Test("memory status shows the limit and caps inference at it")
    func statusLinesShowLimit() {
        let lines = Memory.statusLines(
            provider: ProviderSettings(name: "p", memoryReserveGB: 4, memoryLimitGB: 150),
            physicalGb: 256,
            configDescription: "cfg"
        )
        #expect(lines.contains("Physical memory: 256 GB"))
        #expect(lines.contains("Memory limit: 150 GB"))
        // Effective cap = min(90% × 256, 256 − max(4, 256−150)) = min(230.4, 150).
        #expect(lines.contains("Inference cap: 150 GB"))
    }

    @Test("memory status without a limit shows 'none' and the standard cap")
    func statusLinesNoLimit() {
        let lines = Memory.statusLines(
            provider: ProviderSettings(name: "p", memoryReserveGB: 4),
            physicalGb: 256,
            configDescription: "cfg"
        )
        #expect(lines.contains("Memory limit: none"))
        // Cap must fall back to the fraction/reserve bound, not 0 or physical.
        let cap = lines.first { $0.hasPrefix("Inference cap: ") }
        #expect(cap != nil && cap != "Inference cap: 0 GB" && cap != "Inference cap: 256 GB")
    }

    @Test("a configured limit at/above physical is normalized to none in status")
    func statusLinesIgnoresUselessLimit() {
        let lines = Memory.statusLines(
            provider: ProviderSettings(name: "p", memoryReserveGB: 4, memoryLimitGB: 300),
            physicalGb: 256,
            configDescription: "cfg"
        )
        #expect(lines.contains { $0.hasPrefix("Memory limit: none") })
    }

    // MARK: - `darkbloom status` total-memory line

    @Test("status appends the limit to total memory only when it is effective")
    func statusMemoryDescription() {
        #expect(Status.memoryDescription(totalGb: 256, limitGB: 150) == "256 GB (limit: 150 GB)")
        #expect(Status.memoryDescription(totalGb: 256, limitGB: nil) == "256 GB")
        // Normalized-away limits (0, at/above physical) are not shown.
        #expect(Status.memoryDescription(totalGb: 256, limitGB: 0) == "256 GB")
        #expect(Status.memoryDescription(totalGb: 256, limitGB: 256) == "256 GB")
        #expect(Status.memoryDescription(totalGb: 256, limitGB: 300) == "256 GB")
    }

    // MARK: - fitWarnings (models a new limit evicts)

    private func model(_ id: String, gb: Double) -> ModelInfo {
        ModelInfo(id: id, sizeBytes: UInt64(gb * 1_073_741_824), estimatedMemoryGb: gb)
    }

    private func settings(limit: UInt64?) -> ProviderSettings {
        ProviderSettings(name: "p", memoryReserveGB: 4, memoryLimitGB: limit)
    }

    @Test("a roomy limit warns about nothing")
    func fitWarningsSilentWhenEverythingFits() {
        let advertised = [model("small", gb: 6), model("big", gb: 26)]
        #expect(
            Memory.fitWarnings(
                provider: settings(limit: 150), physicalGb: 256, advertised: advertised
            ).isEmpty)
    }

    @Test("a limit that evicts some models names them")
    func fitWarningsNamesEvictedModels() {
        let advertised = [model("small", gb: 6), model("big", gb: 26)]
        let lines = Memory.fitWarnings(
            provider: settings(limit: 16), physicalGb: 256, advertised: advertised)
        #expect(lines.contains { $0.contains("big") })
        #expect(!lines.contains { $0.contains("- small") })
        // Some models still fit, so this is not the earnings-zeroing case.
        #expect(!lines.contains { $0.contains("NO base rewards") })
    }

    @Test("a limit that fits nothing warns that base rewards go to zero")
    func fitWarningsFlagsTheZeroEarningsCase() {
        // 8 GB is a VALID limit (>= the floor, below physical) that still cannot
        // load a 26 GB model — the case a range check alone would wave through.
        let lines = Memory.fitWarnings(
            provider: settings(limit: 8), physicalGb: 256, advertised: [model("big", gb: 26)])
        #expect(lines.contains { $0.contains("NO advertised model fits") })
        #expect(lines.contains { $0.contains("NO base rewards") })
    }

    @Test("no advertised models means no warnings to give")
    func fitWarningsEmptyWithoutModels() {
        #expect(
            Memory.fitWarnings(provider: settings(limit: 8), physicalGb: 256, advertised: [])
                .isEmpty)
    }
}
