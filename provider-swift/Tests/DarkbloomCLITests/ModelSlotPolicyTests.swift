import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Onboarding resident-model limit")
struct ModelSlotPolicyTests {
    private func review(
        _ inputs: [String?], current: UInt64 = 3,
        save: (UInt64) throws -> Void = { _ in }
    ) throws -> Bool {
        var remaining = inputs
        return try Start.reviewModelSlots(
            selectedCount: 6, current: current,
            readInput: { remaining.isEmpty ? nil : remaining.removeFirst() },
            emit: { _ in }, saveLimit: save)
    }

    @Test("Enter, EOF and invalid input retain a nondefault limit without writing")
    func preserveCurrent() throws {
        for inputs: [String?] in [[""], [nil], ["x", "x", "x"], ["2", nil],
                                  ["2", ""], ["2", "8"], ["2", "0", "-1", "1.5"]] {
            var writes: [UInt64] = []
            #expect(try review(inputs, current: 8, save: { writes.append($0) }))
            #expect(writes.isEmpty)
        }
    }

    @Test("Explicit slot changes are saved once, including after an invalid value")
    func explicitChange() throws {
        var writes: [UInt64] = []
        #expect(try review(["2", "0", "4"], save: { writes.append($0) }))
        #expect(writes == [4])
    }

    @Test("Returning to model selection does not persist a limit")
    func reselect() throws {
        var writes: [UInt64] = []
        #expect(try !review(["3"], save: { writes.append($0) }))
        #expect(writes.isEmpty)
    }

    @Test("Failed persistence aborts acceptance and does not print Saved")
    func failedSave() throws {
        enum Failure: Error { case denied }
        var inputs = ["2", "4"]
        var output = ""
        #expect(throws: Failure.self) {
            try Start.reviewModelSlots(
                selectedCount: 6, current: 3,
                readInput: { inputs.isEmpty ? nil : inputs.removeFirst() },
                emit: { output += $0 },
                saveLimit: { _ in throw Failure.denied })
        }
        #expect(!output.contains("Saved"))
    }

    @Test("Limits reject zero, signed, fractional and overflowing integers")
    func validation() {
        for input in ["0", "-1", "+4", "1.5", "abc", "", "\(UInt64.max)", "18446744073709551616"] {
            #expect(ModelSlotPolicy.parseLimit(input) == nil)
        }
        #expect(ModelSlotPolicy.parseLimit(" 4 ") == 4)
        #expect(ModelSlotPolicy.parseLimit("\(Int.max)") == UInt64(Int.max))
    }

    @Test("Slot-limited and memory-limited selections never promise coexistence")
    func honestSummary() {
        #expect(ModelSlotPolicy.summary(selectedCount: 6, configuredLimit: 3)
            == "6 selected · up to 3 resident models (configured limit: 3)")
        #expect(ModelSlotPolicy.selectionAdvice(selectedCount: 6, configuredLimit: 3)
            .contains("replace an idle resident"))
        #expect(ModelSlotPolicy.summary(selectedCount: 2, configuredLimit: 8)
            .contains("up to 2 resident"))
        #expect(ModelSlotPolicy.selectionAdvice(selectedCount: 2, configuredLimit: 8)
            .contains("not guaranteed"))
        #expect(ModelSlotPolicy.summary(selectedCount: 0, configuredLimit: 3)
            .contains("up to 0 resident"))
        // Matches the runtime's legacy minimum-one clamp without Int conversion.
        #expect(ModelSlotPolicy.summary(selectedCount: 2, configuredLimit: 0)
            .contains("up to 1 resident"))
    }

    private func withConfig(_ body: (URL, ProviderConfig) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-slots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("custom.toml")
        let config = ProviderConfig(provider: ProviderSettings(name: "slot-test"))
        try body(url, config)
    }

    @Test("First-run persistence creates the selected config and survives reload")
    func firstRun() throws {
        try withConfig { url, config in
            try setModelSlotLimit(5, configPath: url.path, migrateOnDisk: false)
            let reloaded = try ConfigManager.load(from: url)
            #expect(reloaded.backend.maxModelSlots == 5)
            #expect(reloaded.backend.enabledModels.isEmpty)
            #expect(reloaded.backend.engineV2MaxConcurrent == config.backend.engineV2MaxConcurrent)
        }
    }

    @Test("A later config edit is preserved instead of overwritten by the picker snapshot")
    func preservesConcurrentSettings() throws {
        try withConfig { url, original in
            var newer = original
            newer.provider.memoryReserveGB = 12
            newer.backend.idleTimeoutMins = 17
            newer.backend.enabledModels = ["chosen-model"]
            newer.backend.engineV2MaxConcurrent = 6
            try ConfigManager.save(newer, to: url)
            try setModelSlotLimit(4, configPath: url.path, migrateOnDisk: false)
            newer.backend.maxModelSlots = 4
            #expect(try ConfigManager.load(from: url) == newer)
        }
    }

    @Test("Malformed config is left intact and a bad limit never creates config")
    func rejectWithoutOverwrite() throws {
        try withConfig { url, _ in
            #expect(throws: (any Error).self) {
                try setModelSlotLimit(0, configPath: url.path, migrateOnDisk: false)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let malformed = "[backend\nmax_model_slots = 3"
            try malformed.write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) {
                try setModelSlotLimit(4, configPath: url.path, migrateOnDisk: false)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == malformed)
        }
    }
}
