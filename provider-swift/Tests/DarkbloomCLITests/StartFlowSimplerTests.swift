import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// A simpler start: the experimental Autopilot question only for the Darkbloom network, a model picker that opens on
/// what fits this Mac (the last selection, else a downloaded model with room to spare, never one it would download),
/// and no start screen that prints the local key.
@Suite("A simpler start: the Autopilot question, the picker's default, no key on screen")
struct StartFlowSimplerTests {
    @Test("the Autopilot question is asked only for the Darkbloom network; Both, me first and Only me never ask")
    func autopilotOnlyForTheNetwork() throws {
        var config = ProviderConfig(provider: ProviderSettings(name: "flow"))
        let start = try Start.parse([])
        var asked = 0
        let ask: (Bool) -> Bool = { _ in asked += 1; return true }
        #expect(try start.resolveAutopilotChoice(config, mode: .network, interactive: true, ask: ask))
        #expect(asked == 1)
        #expect(try !start.resolveAutopilotChoice(config, mode: .both, interactive: true, ask: ask))
        #expect(try !start.resolveAutopilotChoice(config, mode: .local, interactive: true, ask: ask))
        #expect(asked == 1, "Both, me first and Only me never ask")
        #expect(try Start.parse(["--autopilot"]).resolveAutopilotChoice(config, mode: .both, interactive: true, ask: ask))
        #expect(asked == 1, "an explicit flag still decides, without a question")
        // Without the question, a saved enrollment stands.
        config.backend.modelAutopilot = .init(enabled: true, consentRecorded: true, selectedModels: ["chosen"],
                                              revision: "saved")
        #expect(try start.resolveAutopilotChoice(config, mode: .both, interactive: true, ask: ask))
        #expect(asked == 1)
    }

    private static let memory = 256.0

    /// A picker row of `fraction` of this Mac's load budget for that model.
    private static func entry(_ id: String, fraction: Double, downloaded: Bool = true) -> Start.PickerEntry {
        let gb = fraction * Start.pickerLoadBudgetGiB(memoryGb: memory, modelIDs: [id])
        return Start.PickerEntry(id: id, catalogModel: CatalogModel(id: id, s3Name: id, displayName: id, sizeGb: gb),
                                 displayName: id, sizeGb: gb, minRamGb: nil, downloaded: downloaded)
    }

    private static func preselected(_ entries: [Start.PickerEntry], lastUsed: [String] = []) -> [String] {
        Start.pickerPreselection(entries: entries, memoryGb: memory, reserveMode: .selectedModels, lastUsed: lastUsed)
            .map { entries[$0].id }
    }

    /// Before, the picker pre-selected the biggest downloaded model that fit: MiMo, 176 GiB, on a 256 GB Mac.
    @Test("the picker opens on the last selection, else a downloaded model with room to spare, never the biggest")
    func pickerDefault() {
        // Downloaded first, larger first, as the picker lists them.
        let entries = [Self.entry("mimo", fraction: 0.9), Self.entry("qwen", fraction: 0.3),
                       Self.entry("gemma", fraction: 0.1), Self.entry("catalog-only", fraction: 0.01, downloaded: false)]
        #expect(Self.preselected(entries) == ["qwen"], "the largest with room to spare, not mimo at 90% of the budget")
        #expect(Self.preselected(entries, lastUsed: ["gemma"]) == ["gemma"], "the last selection")
        #expect(Self.preselected(entries, lastUsed: ["gemma", "catalog-only", "mimo"]) == ["mimo", "gemma"],
                "the last selection's models still downloaded, the biggest included")
        #expect(Self.preselected(entries, lastUsed: ["catalog-only"]) == ["qwen"], "never a model only the catalog has")
        // Nothing with room to spare: the smallest that fits. Nothing downloaded: nothing selected.
        #expect(Self.preselected([Self.entry("big", fraction: 0.8), Self.entry("bigger", fraction: 0.9)]) == ["big"])
        #expect(Self.preselected([Self.entry("x", fraction: 0.1, downloaded: false)]).isEmpty)
    }

    @Test("--local --here shows where the key is, never the key, and where your requests go")
    func noKeyInTheBanner() throws {
        let config = try TempConfig("[provider]\nname = \"flow\"\n\n[local]\nroute = \"my-macs\"\n")
        defer { config.remove() }
        var lookups = 0
        let environment = ServingEnvironment(terminal: true, readInput: { nil }, emit: { _ in },
                                             accountKeySaved: { lookups += 1; return true }, ownLivePort: { nil },
                                             installedPort: { nil }, isFree: { _ in true })
        let start = try config.start(["--local", "--here"])
        let serving = try #require(try start.resolveServing(environment: environment))
        #expect(serving.accountKeySaved == true && lookups == 1, "whether a key is saved, read once; never the key")
        let model = ModelInfo(id: "served/gemma", modelType: "gemma4", sizeBytes: 1, estimatedMemoryGb: 1)
        let banner = start.localServerBanner(serving: serving, models: [model], token: "dk-local-fixture")
        #expect(banner.contains("  API key:  `darkbloom local` shows it"))
        #expect(banner.contains("  Your requests: this Mac first, then your other Macs (free)"))
        #expect(!banner.contains { $0.contains("dk-local-fixture") || $0.contains("OPENAI_API_KEY") })
    }
}
