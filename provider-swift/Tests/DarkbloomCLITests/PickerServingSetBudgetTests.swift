import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Pure catalog/selection and admission arithmetic. No scan, download or model
/// load runs. Serialize because the production picker reads process overrides.
@Suite("Picker serving-set memory budget", .serialized)
struct PickerServingSetBudgetTests {
    private let gib = Double(1 << 30)
    private let memoryGiB = 24.0

    private func withMemoryOverrides<T>(
        activationReserve: String? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        let names = ["DARKBLOOM_MEM_CAP_FRACTION", "DARKBLOOM_ACTIVATION_RESERVE_GB"]
        let previous = names.map { name in getenv(name).map { String(cString: $0) } }
        defer {
            for (name, value) in zip(names, previous) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        setenv(names[0], "0.8", 1)
        if let activationReserve { setenv(names[1], activationReserve, 1) }
        else { unsetenv(names[1]) }
        return try body()
    }

    private func entries(
        _ ids: [String], downloaded: Bool = false, smallUnknown: Bool = false
    ) -> [Start.PickerEntry] {
        func downloadGB(_ id: String) -> Double {
            smallUnknown && id == "fixture/unknown" ? gib / (1.2 * 1e9) : 12.1
        }
        return Start.buildPickerEntries(
            rows: ids.map { id in
                let model = CatalogModel(
                    id: id, s3Name: id, displayName: id, sizeGb: downloadGB(id), minRamGb: 24)
                return Start.PickerCatalogRow(model: model, displayName: id)
            },
            downloadedIDs: downloaded ? Set(ids) : [],
            localMemoryByID: Dictionary(uniqueKeysWithValues: ids.map { ($0, downloadGB($0) * 1.2 * 1e9 / gib) }),
            resumableIDs: [],
            memoryGb: memoryGiB)
    }

    private func admissionAllows(_ entry: Start.PickerEntry, servingIDs: [String]) -> Bool {
        let physical = UInt64(memoryGiB * gib)
        return ModelLoadAdmission.canLoad(
            weightsGb: entry.sizeGb,
            headroomGb: Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: servingIDs)) / gib,
            totalBytes: physical,
            systemAvailableBytes: physical,
            gpuActiveBytes: 0,
            gpuCacheBytes: 0,
            reserveBytes: UnifiedMemoryCap.loadReserveBytes(physicalBytes: physical, configReserveBytes: 0))
    }

    @Test("A measured-only choice is not refused using the unknown-model floor", arguments: [false, true])
    func measuredChoiceUsesItsServingSet(downloaded: Bool) throws {
        try withMemoryOverrides {
            let rows = entries(["gpt-oss-20b"], downloaded: downloaded)
            let row = try #require(rows.first)
            #expect(abs(row.sizeGb - 13.522803783416748) < 0.000001)
            #expect(Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: [row.id])) / gib == 4.5)
            #expect(admissionAllows(row, servingIDs: [row.id]))
            let selection = Start.resolveFallbackSelection(input: "1", entries: rows, memoryGb: memoryGiB)
            print("measured selection downloaded=\(downloaded) loadGiB=\(row.sizeGb) actual=\(selection)")
            #expect(selection == .selected([row.id]))
        }
    }

    @Test("Unknown and vision models retain the default floor", arguments: ["fixture/unknown", "qwen3.6-35b-a3b-vl-mtp-mxfp8"])
    func unmeasuredChoiceIsRejected(id: String) throws {
        try withMemoryOverrides {
            let rows = entries([id])
            let row = try #require(rows.first)
            #expect(Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: [id])) / gib == 6.5)
            #expect(!admissionAllows(row, servingIDs: [id]))
            guard case .rejected = Start.resolveFallbackSelection(input: "1", entries: rows, memoryGb: memoryGiB) else {
                Issue.record("Unmeasured model must remain rejected")
                return
            }
        }
    }

    @Test("A mixed selection keeps the higher floor in either order", arguments: ["1,2", "2,1"])
    func mixedChoiceIsRejected(input: String) throws {
        try withMemoryOverrides {
            let rows = entries(["gpt-oss-20b", "fixture/unknown"], smallUnknown: true)
            let measured = try #require(rows.first { $0.id == "gpt-oss-20b" })
            let unknown = try #require(rows.first { $0.id == "fixture/unknown" })
            #expect(admissionAllows(measured, servingIDs: [measured.id]))
            #expect(admissionAllows(unknown, servingIDs: [unknown.id]))
            #expect(!admissionAllows(measured, servingIDs: rows.map(\.id)))
            guard case .rejected = Start.resolveFallbackSelection(input: input, entries: rows, memoryGb: memoryGiB) else {
                Issue.record("Mixed serving set must retain the unknown-model reserve")
                return
            }
        }
    }

    @Test("A raised operator reserve remains effective")
    func raisedReserveIsRejected() throws {
        try withMemoryOverrides(activationReserve: "6") {
            let rows = entries(["gpt-oss-20b"])
            let row = try #require(rows.first)
            #expect(Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: [row.id])) / gib == 7)
            #expect(!admissionAllows(row, servingIDs: [row.id]))
            guard case .rejected = Start.resolveFallbackSelection(input: "1", entries: rows, memoryGb: memoryGiB) else {
                Issue.record("Raised operator reserve must retain the rejection")
                return
            }
        }
    }

    @Test("An empty input remains cancellation")
    func emptyChoiceCancels() {
        withMemoryOverrides {
            #expect(Start.resolveFallbackSelection(input: "", entries: entries(["gpt-oss-20b"]), memoryGb: memoryGiB) == .cancelled)
        }
    }

    @Test("All keeps a measured-only choice when no unmeasured row can fit")
    func allUsesTheSelectedSet() {
        withMemoryOverrides {
            let rows = entries(["gpt-oss-20b", "fixture/unknown"])
            #expect(Start.resolveFallbackSelection(input: "all", entries: rows, memoryGb: memoryGiB)
                == .selected(["gpt-oss-20b"]))
        }
    }

    @Test("All retains the higher floor when it includes a small unknown model")
    func allMixedSetKeepsTheFloor() {
        withMemoryOverrides {
            let rows = entries(["gpt-oss-20b", "fixture/unknown"], smallUnknown: true)
            #expect(Start.resolveFallbackSelection(input: "all", entries: rows, memoryGb: memoryGiB)
                == .selected(["fixture/unknown"]))
        }
    }

    /// Like the existing terminal picker suite, use datagrams to preserve key
    /// boundaries and a file for output. No real terminal or provider is used.
    private func terminalSelection(
        _ rows: [Start.PickerEntry], preselect: Bool = false,
        reserveMode: Start.PickerReserveMode = .selectedModels, keys: [[UInt8]]
    ) throws -> [Int] {
        var sockets: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets) == 0)
        defer { close(sockets[0]); close(sockets[1]) }
        for key in keys + [[0x71], [0x71]] {
            let written = key.withUnsafeBytes { write(sockets[1], $0.baseAddress, $0.count) }
            try #require(written == key.count)
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-reserve-\(UUID().uuidString).out")
        let outputFD = open(output.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        try #require(outputFD >= 0)
        defer { close(outputFD); try? FileManager.default.removeItem(at: output) }
        return try Start.parse([]).runModelPicker(
            entries: rows, memoryGb: memoryGiB, reserveMode: reserveMode, preselectDownloaded: preselect,
            inputFD: sockets[0], outputFD: outputFD)
    }

    @Test("The TUI accepts a measured-only choice", arguments: [false, true])
    func terminalMeasuredChoice(downloaded: Bool) throws {
        try withMemoryOverrides {
            let rows = entries(["gpt-oss-20b"], downloaded: downloaded)
            let keys: [[UInt8]] = downloaded ? [[0x0D]] : [[0x20], [0x0D]]
            let selection = try terminalSelection(rows, preselect: downloaded, keys: keys)
            #expect(selection == [0])
        }
    }

    @Test("The TUI refuses additions that invalidate an existing selection", arguments: [false, true])
    func terminalMixedChoice(reverse: Bool) throws {
        try withMemoryOverrides {
            let original = entries(["gpt-oss-20b", "fixture/unknown"], smallUnknown: true)
            let rows = reverse ? Array(original.reversed()) : original
            let selection = try terminalSelection(rows, keys: [[0x20], [0x1B, 0x5B, 0x42], [0x20], [0x0D]])
            #expect(selection == [0])
        }
    }

    @Test("Autopilot enrollment preserves its conservative picker gate", arguments: [false, true])
    func autopilotKeepsDefaultReserve(downloaded: Bool) throws {
        try withMemoryOverrides {
            let rows = entries(["gpt-oss-20b"], downloaded: downloaded)
            let row = try #require(rows.first)
            // verifiedAutopilotInventory deliberately uses this no-ID gate.
            #expect(!Start.modelFitsBudget(sizeGb: row.sizeGb, memoryGb: memoryGiB))
            for input in ["1", "all"] {
                guard case .rejected = Start.resolveFallbackSelection(
                    input: input, entries: rows, memoryGb: memoryGiB, reserveMode: .autopilotInventory
                ) else {
                    Issue.record("Autopilot selection must retain its existing reserve")
                    return
                }
            }
            let selection = try terminalSelection(
                rows, preselect: downloaded, reserveMode: .autopilotInventory, keys: [[0x20], [0x0D]])
            #expect(selection.isEmpty)
        }
    }

    @Test("The selected-model budget retains exact size and invalid-value boundaries")
    func selectedBudgetBoundary() {
        withMemoryOverrides {
            let ids = ["gpt-oss-20b"]
            let budget = Start.pickerLoadBudgetGiB(memoryGb: memoryGiB, modelIDs: ids)
            #expect(abs(budget - 14.7) < 0.000001)
            #expect(Start.modelFitsBudget(sizeGb: budget, memoryGb: memoryGiB, modelIDs: ids))
            #expect(!Start.modelFitsBudget(sizeGb: budget.nextUp, memoryGb: memoryGiB, modelIDs: ids))
            for size in [0, -1, Double.nan, Double.infinity] {
                #expect(!Start.modelFitsBudget(sizeGb: size, memoryGb: memoryGiB, modelIDs: ids))
            }
            #expect(Start.pickerLoadBudgetGiB(memoryGb: 0, modelIDs: ids) == 0)
            #expect(Start.pickerLoadBudgetGiB(memoryGb: 5000, modelIDs: ids) == 0)
        }
    }

    @Test("A lower operator override cannot lower the measured floor")
    func activationOverrideCannotLowerFloor() {
        withMemoryOverrides(activationReserve: "1") {
            #expect(Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: ["gpt-oss-20b"])) / gib == 4.5)
            #expect(Start.resolveFallbackSelection(
                input: "1", entries: entries(["gpt-oss-20b"]), memoryGb: memoryGiB
            ) == .selected(["gpt-oss-20b"]))
        }
    }
}
