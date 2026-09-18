import Foundation
import Testing

@testable import ProviderCore

private let qwen38ID = ModelRuntimeRequirements.qwen38ConcreteModelID
private let qwen38Caps: Set<ProviderRuntimeCapability> = [.appleM5, .mlxNAX]

@Suite("Provider capability labels")
struct ProviderCapabilityLabelsTests {
    @Test("known capabilities map to operator-facing names")
    func knownLabels() {
        #expect(ProviderCapabilityLabels.label(for: .appleM5) == "Apple M5")
        #expect(ProviderCapabilityLabels.label(for: .mlxNAX) == "NAX runtime")
    }

    @Test("unknown capabilities fall back to the raw wire id")
    func unknownLabel() {
        let future = ProviderRuntimeCapability(rawValue: "future_runtime")
        #expect(ProviderCapabilityLabels.label(for: future) == "future_runtime")
    }

    @Test("labels are ordered by wire id and de-duplicated")
    func labelsOrdering() {
        #expect(
            ProviderCapabilityLabels.labels([.mlxNAX, .appleM5, .mlxNAX])
                == ["Apple M5", "NAX runtime"])
        #expect(ProviderCapabilityLabels.labels([]).isEmpty)
    }
}

@Suite("Model requirement lines")
struct ModelRequirementLineTests {
    @Test("requires line lists labels in wire-id order and is nil when empty")
    func requiresLine() {
        #expect(ModelRequirementLine.requires(qwen38Caps) == "requires: Apple M5, NAX runtime")
        #expect(ModelRequirementLine.requires([.mlxNAX]) == "requires: NAX runtime")
        #expect(ModelRequirementLine.requires([]) == nil)
    }

    @Test("ineligible line uses raw ids like the download error and is nil when nothing is missing")
    func ineligibleLine() {
        #expect(
            ModelRequirementLine.ineligible(missing: qwen38Caps)
                == "not eligible on this machine (missing: apple_m5, mlx_nax)")
        #expect(
            ModelRequirementLine.ineligible(missing: [.mlxNAX])
                == "not eligible on this machine (missing: mlx_nax)")
        #expect(ModelRequirementLine.ineligible(missing: []) == nil)
    }

    @Test("models without requirements print nothing")
    func noRequirement() {
        #expect(ModelRequirementLine.lines(
            modelID: "unrelated/model", catalogRequirements: nil, available: []).isEmpty)
        #expect(ModelRequirementLine.lines(
            modelID: "unrelated/model", catalogRequirements: [], available: nil).isEmpty)
    }

    @Test("catalog requirement on an M4-class box explains the missing capabilities")
    func catalogRequirementIneligible() {
        let lines = ModelRequirementLine.lines(
            modelID: "vendor/future-model",
            catalogRequirements: [.mlxNAX, .appleM5],
            available: [.mlxNAX])
        #expect(lines == [
            "requires: Apple M5, NAX runtime",
            "not eligible on this machine (missing: apple_m5)",
        ])
    }

    @Test("an eligible machine sees only the requires line")
    func catalogRequirementEligible() {
        let lines = ModelRequirementLine.lines(
            modelID: "vendor/future-model",
            catalogRequirements: [.appleM5, .mlxNAX],
            available: qwen38Caps)
        #expect(lines == ["requires: Apple M5, NAX runtime"])
    }

    @Test("embedded exact-id rule surfaces even when the catalog carries no requirement")
    func embeddedRuleWithoutCatalogField() {
        for modelID in ModelRuntimeRequirements.qwen38ConcreteModelIDs {
            let lines = ModelRequirementLine.lines(
                modelID: modelID, catalogRequirements: nil, available: [])
            #expect(lines == [
                "requires: Apple M5, NAX runtime",
                "not eligible on this machine (missing: apple_m5, mlx_nax)",
            ], "\(modelID)")
        }
    }

    @Test("embedded rule unions with catalog requirements and unknown values keep their raw id")
    func embeddedRuleUnionsWithCatalog() {
        let future = ProviderRuntimeCapability(rawValue: "future_runtime")
        let lines = ModelRequirementLine.lines(
            modelID: qwen38ID, catalogRequirements: [future], available: qwen38Caps)
        // Ordered by wire id (apple_m5 < future_runtime < mlx_nax), not by label.
        #expect(lines == [
            "requires: Apple M5, future_runtime, NAX runtime",
            "not eligible on this machine (missing: future_runtime)",
        ])
    }

    @Test("failed hardware detection reports unknown, never ineligible")
    func hardwareUnknown() {
        let lines = ModelRequirementLine.lines(
            modelID: qwen38ID, catalogRequirements: nil, available: nil)
        #expect(lines == [
            "requires: Apple M5, NAX runtime",
            ModelRequirementLine.hardwareUnknown,
        ])
    }
}
