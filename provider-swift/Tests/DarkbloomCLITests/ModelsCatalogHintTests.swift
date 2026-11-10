import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// The note `darkbloom models catalog` prints under its table. The Mac here
/// has 128 GB. Models meant to fit are at most 40 GB and the one meant not to
/// fit is larger than the Mac's memory, so the memory-cap overrides another
/// suite sets in this process cannot change a verdict.
@Suite("models catalog: not-downloaded models this Mac can select")
struct ModelsCatalogHintTests {
    private func model(
        _ id: String, displayName: String? = nil, sizeGb: Double = 10, minRamGb: Int? = 24,
        modelType: String = "text", active: Bool? = nil, metadata: [String: JSONValue]? = nil,
        requiredCapabilities: [ProviderRuntimeCapability]? = nil
    ) -> CatalogModel {
        CatalogModel(
            id: id, s3Name: id, displayName: displayName ?? id, modelType: modelType, sizeGb: sizeGb,
            minRamGb: minRamGb, active: active, r2Prefix: "v2/\(id)/v1", metadata: metadata,
            requiredProviderCapabilities: requiredCapabilities)
    }

    private func candidateIDs(
        _ entries: [CatalogModel], aliases: [CatalogAlias] = [], downloaded: Set<String> = [],
        capabilities: Set<ProviderRuntimeCapability> = []
    ) -> [String] {
        ModelsCatalogHint.candidates(
            entries: entries, aliases: aliases, downloadedIDs: downloaded, memoryGb: 128,
            runtimeCapabilities: capabilities
        ).map(\.id)
    }

    @Test("lists what is not downloaded, larger first, and leaves out what is")
    func notDownloadedLargerFirst() {
        let entries = [
            model("acme/small", sizeGb: 6), model("acme/have", sizeGb: 20),
            model("acme/large", sizeGb: 40, minRamGb: 64),
        ]
        #expect(candidateIDs(entries, downloaded: ["acme/have"]) == ["acme/large", "acme/small"])
        #expect(candidateIDs(entries, downloaded: ["acme/small", "acme/have", "acme/large"]).isEmpty)
    }

    @Test("a listed min_ram_gb is compared as the coordinator does; an unlisted tier is not guessed")
    func memoryTier() {
        let entries = [
            model("acme/at-tier", minRamGb: 128), model("acme/above-tier", minRamGb: 129),
            model("acme/no-tier", minRamGb: nil), model("acme/zero-tier", minRamGb: 0),
        ]
        #expect(candidateIDs(entries) == ["acme/at-tier"])
    }

    @Test("a model whose required runtime capabilities this Mac lacks is left out")
    func runtimeCapabilities() {
        let entries = [
            model("acme/gated", requiredCapabilities: [.appleM5, .mlxNAX]),
            // No catalog requirement: the embedded exact-ID rule still applies.
            model(ModelRuntimeRequirements.qwen38ConcreteModelID, sizeGb: 16, minRamGb: 36),
        ]
        #expect(candidateIDs(entries, capabilities: [.appleM5]).isEmpty)
        #expect(
            candidateIDs(entries, capabilities: [.appleM5, .mlxNAX])
                == [ModelRuntimeRequirements.qwen38ConcreteModelID, "acme/gated"])
    }

    @Test("inactive, non-text and picker-hidden builds are left out")
    func hiddenBuilds() {
        let entries = [
            model("acme/image", modelType: "image"), model("acme/inactive", active: false),
            model("acme/rollback", displayName: "Acme 8-bit (rollback)"),
            model("acme/hidden", metadata: ["hidden_from_picker": .bool(true)]),
            model("acme/not-standalone", metadata: ["hide_standalone": .bool(true)]),
            // The picker's Gemma rollout rule: only the QAT build is offered.
            model("gemma-4-26b", sizeGb: 28, minRamGb: 36),
            model("gemma-4-26b-8bit", sizeGb: 28, minRamGb: 64),
            model("gemma-4-26b-qat-4bit", sizeGb: 16, minRamGb: 36),
            model("acme/active", active: true),
        ]
        #expect(candidateIDs(entries) == ["gemma-4-26b-qat-4bit", "acme/active"])
        // The picker hides the older Gemma build for a QAT row this note would not name either.
        let inactiveQAT = [
            model("gemma-4-26b", sizeGb: 28, minRamGb: 36),
            model("gemma-4-26b-qat-4bit", sizeGb: 16, minRamGb: 36, active: false),
        ]
        #expect(candidateIDs(inactiveQAT).isEmpty)
    }

    @Test("under a public alias only the build the picker offers this Mac is named")
    func aliasedBuilds() {
        let entries = [
            model("acme/v2", sizeGb: 12, requiredCapabilities: [.appleM5]), model("acme/v1", sizeGb: 11),
            model("acme/v0", sizeGb: 9), model("acme/other", sizeGb: 8),
        ]
        let alias = CatalogAlias(
            id: "acme", displayName: "Acme", desiredBuild: "acme/v2", previousBuild: "acme/v1",
            retiredBuilds: ["acme/v0"], primaryBuild: nil)
        #expect(candidateIDs(entries, aliases: [alias], capabilities: [.appleM5]) == ["acme/v2", "acme/other"])
        // Without the desired build's capability the picker offers the previous build.
        #expect(candidateIDs(entries, aliases: [alias]) == ["acme/v1", "acme/other"])
    }

    @Test("a model over the provider's load budget is left out although its tier is met")
    func loadBudget() {
        let entries = [
            model("acme/over-budget", sizeGb: 120, minRamGb: 128),
            model("acme/fits", sizeGb: 40, minRamGb: 128),
        ]
        #expect(candidateIDs(entries) == ["acme/fits"])
    }

    @Test("each model is one row with its id and download size, then the commands; no model, no lines")
    func exactLines() {
        let candidates = [
            model("acme/large", displayName: "Acme Large", sizeGb: 19.05959583),
            model("acme/small", displayName: "Acme Small", sizeGb: 6.11395223),
        ]
        #expect(
            ModelsCatalogHint.lines(candidates: candidates, cliName: "darkbloom-dev") == [
                "",
                "Not downloaded (this Mac meets their listed requirements)",
                "",
                "  Acme Large  [acme/large]  ~19.1 GB download",
                "  Acme Small  [acme/small]  ~6.1 GB download",
                "",
                "  Not checked: free disk space, memory reserved or in use when a model loads, provider version and trust status.",
                "  Download one: darkbloom-dev models download <id>",
                "  Then choose what to serve: darkbloom-dev switch (darkbloom-dev start when the provider is stopped)",
            ])
        #expect(ModelsCatalogHint.lines(candidates: [], cliName: "darkbloom").isEmpty)
    }

    @Test("at most three rows are printed; the rest are counted")
    func rowLimit() {
        let candidates = (1...5).map { model("acme/m\($0)", displayName: "M\($0)", sizeGb: Double($0)) }
        let lines = ModelsCatalogHint.lines(candidates: candidates, cliName: "darkbloom")
        #expect(
            Array(lines.dropFirst(3).prefix(4)) == [
                "  M1  [acme/m1]  ~1.0 GB download", "  M2  [acme/m2]  ~2.0 GB download",
                "  M3  [acme/m3]  ~3.0 GB download",
                "  … and 2 more; the darkbloom switch picker lists them all",
            ])
        let three = ModelsCatalogHint.lines(candidates: Array(candidates.prefix(3)), cliName: "darkbloom")
        #expect(three.count == lines.count - 1)
    }
}
