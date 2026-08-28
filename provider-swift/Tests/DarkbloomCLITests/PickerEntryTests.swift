import Foundation
import Testing
import ProviderCore

@testable import darkbloom

/// Unit tests for the pure picker-entry classifier `Start.buildPickerEntries`.
///
/// The key invariant (the "invisible after interruption" fix): a model that is
/// physically on disk reads "downloaded" even when it exceeds available RAM —
/// `downloaded` is computed from an UNFILTERED on-disk check, never the
/// memory-filtered scan. Resumable (interrupted-download) builds are flagged so
/// the picker can show "resuming" rather than "not downloaded".
@Suite("Start.buildPickerEntries classification")
struct PickerEntryTests {

    private func model(
        _ id: String,
        displayName: String? = nil,
        sizeGb: Double = 10,
        minRamGb: Int? = nil,
        requiredCapabilities: [ProviderRuntimeCapability]? = nil
    ) -> CatalogModel {
        CatalogModel(
            id: id,
            s3Name: id,
            displayName: displayName ?? id,
            sizeGb: sizeGb,
            minRamGb: minRamGb,
            r2Prefix: "v2/\(id)/v1",
            requiredProviderCapabilities: requiredCapabilities
        )
    }

    private func row(_ m: CatalogModel) -> Start.PickerCatalogRow {
        Start.PickerCatalogRow(model: m, displayName: m.displayName)
    }

    private func entry(_ id: String, sizeGb: Double, downloaded: Bool = true) -> Start.PickerEntry {
        Start.PickerEntry(
            id: id,
            catalogModel: model(id, sizeGb: sizeGb),
            displayName: id,
            sizeGb: sizeGb,
            minRamGb: nil,
            downloaded: downloaded
        )
    }

    private func alias(
        id: String,
        displayName: String,
        desired: String,
        previous: String? = nil,
        retired: [String]? = nil,
        primary: String? = nil
    ) throws -> CatalogAlias {
        var object: [String: Any] = [
            "id": id,
            "display_name": displayName,
            "desired_build": desired,
        ]
        if let previous {
            object["previous_build"] = previous
        }
        if let retired {
            object["retired_builds"] = retired
        }
        if let primary {
            object["primary_build"] = primary
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CatalogAlias.self, from: data)
    }

    private func pickerRows(
        models: [CatalogModel],
        aliases: [CatalogAlias],
        runtimeCapabilities: Set<ProviderRuntimeCapability> = []
    ) -> [Start.PickerCatalogRow] {
        let catalog = Start.evaluateEligiblePickerCatalog(
            models: models,
            aliases: aliases,
            runtimeCapabilities: runtimeCapabilities)
        return Start.pickerCatalogRows(catalog: catalog)
    }

    // MARK: - Runtime eligibility and public aliases

    @Test("protected desired build falls back to the eligible previous build")
    func protectedDesiredUsesEligiblePrevious() throws {
        let desiredID = ModelRuntimeRequirements.qwen38ConcreteModelID
        let previousID = "EigenLabs/Qwen3.8-27B-previous"
        let publicName = "Qwen 3.8 27B"
        let rows = pickerRows(
            models: [model(desiredID), model(previousID)],
            aliases: [
                try alias(
                    id: "qwen-3.8-27b",
                    displayName: publicName,
                    desired: desiredID,
                    previous: previousID,
                    primary: desiredID),
            ])

        #expect(rows.map(\.model.id) == [previousID])
        #expect(rows.map(\.displayName) == [publicName])
    }

    @Test("when both alias builds are eligible the desired build wins")
    func bothEligibleUsesDesiredAndHidesPrevious() throws {
        let desiredID = ModelRuntimeRequirements.qwen38ConcreteModelID
        let previousID = "EigenLabs/Qwen3.8-27B-previous"
        let publicName = "Qwen 3.8 27B"
        let rows = pickerRows(
            models: [model(desiredID), model(previousID)],
            aliases: [
                try alias(
                    id: "qwen-3.8-27b",
                    displayName: publicName,
                    desired: desiredID,
                    previous: previousID,
                    primary: desiredID),
            ],
            runtimeCapabilities: ModelRuntimeRequirements.qwen38RequiredCapabilities)

        #expect(rows.map(\.model.id) == [desiredID])
        #expect(rows.map(\.displayName) == [publicName])
    }

    @Test("an alias is omitted when neither desired nor previous is eligible")
    func neitherAliasBuildEligibleIsOmitted() throws {
        let desiredID = ModelRuntimeRequirements.qwen38ConcreteModelID
        let previousID = "EigenLabs/Qwen3.8-27B-previous"
        let rows = pickerRows(
            models: [
                model(desiredID),
                model(previousID, requiredCapabilities: [.mlxNAX]),
            ],
            aliases: [
                try alias(
                    id: "qwen-3.8-27b",
                    displayName: "Qwen 3.8 27B",
                    desired: desiredID,
                    previous: previousID,
                    primary: desiredID),
            ])

        #expect(rows.isEmpty)
    }

    @Test("an unrelated alias still selects its eligible desired build")
    func unrelatedAliasStillUsesEligibleDesired() throws {
        let qwenPreviousID = "EigenLabs/Qwen3.8-27B-previous"
        let otherDesiredID = "EigenLabs/Other-Model-v2"
        let otherPreviousID = "EigenLabs/Other-Model-v1"
        let rows = pickerRows(
            models: [
                model(ModelRuntimeRequirements.qwen38ConcreteModelID),
                model(qwenPreviousID, requiredCapabilities: [.mlxNAX]),
                model(otherDesiredID),
                model(otherPreviousID),
            ],
            aliases: [
                try alias(
                    id: "qwen-3.8-27b",
                    displayName: "Qwen 3.8 27B",
                    desired: ModelRuntimeRequirements.qwen38ConcreteModelID,
                    previous: qwenPreviousID,
                    primary: ModelRuntimeRequirements.qwen38ConcreteModelID),
                try alias(
                    id: "other-model",
                    displayName: "Other Model",
                    desired: otherDesiredID,
                    previous: otherPreviousID,
                    primary: otherDesiredID),
            ])

        #expect(rows.map(\.model.id) == [otherDesiredID])
        #expect(rows.map(\.displayName) == ["Other Model"])
    }

    // MARK: - resolveFallbackSelection (non-TTY picker won't-fit guard)

    @Test("fallback 'all' selects only models that fit in RAM")
    func fallbackAllExcludesWontFit() {
        let small = entry("org/small", sizeGb: 8)
        let huge = entry("org/huge", sizeGb: 200)
        // 18 GB box → 14 GB budget: small fits, huge does not.
        let r = Start.resolveFallbackSelection(input: "all", entries: [small, huge], memoryGb: 18)
        #expect(r == .selected(["org/small"]))
    }

    @Test("fallback rejects an explicit won't-fit pick instead of serving it")
    func fallbackRejectsWontFitIndex() {
        let small = entry("org/small", sizeGb: 8)
        let huge = entry("org/huge", sizeGb: 200)
        guard case .rejected = Start.resolveFallbackSelection(input: "2", entries: [small, huge], memoryGb: 18) else {
            Issue.record("expected a won't-fit explicit selection to be rejected")
            return
        }
    }

    @Test("fallback selects explicit fitting models in order")
    func fallbackSelectsFitting() {
        let small = entry("org/small", sizeGb: 8)
        let mid = entry("org/mid", sizeGb: 12)
        #expect(
            Start.resolveFallbackSelection(input: "1,2", entries: [small, mid], memoryGb: 18)
                == .selected(["org/small", "org/mid"]))
    }

    @Test("fallback rejects 'all' when nothing fits")
    func fallbackRejectsAllTooBig() {
        let huge = entry("org/huge", sizeGb: 200)
        guard case .rejected = Start.resolveFallbackSelection(input: "all", entries: [huge], memoryGb: 18) else {
            Issue.record("expected rejection when no model fits")
            return
        }
    }

    @Test("fallback empty input cancels, out-of-range and non-numeric are rejected")
    func fallbackEmptyAndRange() {
        let small = entry("org/small", sizeGb: 8)
        #expect(Start.resolveFallbackSelection(input: "", entries: [small], memoryGb: 18) == .cancelled)
        #expect(Start.resolveFallbackSelection(input: "   ", entries: [small], memoryGb: 18) == .cancelled)
        guard case .rejected = Start.resolveFallbackSelection(input: "5", entries: [small], memoryGb: 18) else {
            Issue.record("expected out-of-range rejection")
            return
        }
        guard case .rejected = Start.resolveFallbackSelection(input: "x", entries: [small], memoryGb: 18) else {
            Issue.record("expected non-numeric rejection")
            return
        }
    }

    @Test("a downloaded-but-too-big model still shows downloaded (never hidden by RAM)")
    func tooBigDownloadedShowsDownloaded() {
        let big = model("org/too-big", sizeGb: 200, minRamGb: 256)  // far over an 18 GB box
        let entries = Start.buildPickerEntries(
            rows: [row(big)],
            downloadedIDs: ["org/too-big"],            // present on disk (UNFILTERED)
            localMemoryByID: ["org/too-big": 240.0],   // way over budget
            resumableIDs: [],
            memoryGb: 18
        )
        #expect(entries.count == 1)
        #expect(entries[0].id == "org/too-big")
        #expect(entries[0].downloaded == true, "a model on disk must read downloaded even when it won't fit")
        // Sized from the on-disk estimate, not the catalog size.
        #expect(entries[0].sizeGb == 240.0)
    }

    @Test("a NOT-downloaded model whose min RAM exceeds the box is hidden")
    func tooBigNotDownloadedHidden() {
        let big = model("org/too-big", sizeGb: 200, minRamGb: 256)
        let entries = Start.buildPickerEntries(
            rows: [row(big)],
            downloadedIDs: [],
            localMemoryByID: [:],
            resumableIDs: [],
            memoryGb: 18
        )
        #expect(entries.isEmpty, "an unrunnable model that isn't on disk should not clutter the picker")
    }

    @Test("an interrupted (staged) not-downloaded model is flagged resumable")
    func stagedModelIsResumable() {
        let m = model("org/partial", sizeGb: 12, minRamGb: 16)
        let entries = Start.buildPickerEntries(
            rows: [row(m)],
            downloadedIDs: [],
            localMemoryByID: [:],
            resumableIDs: ["org/partial"],
            memoryGb: 32
        )
        #expect(entries.count == 1)
        #expect(entries[0].downloaded == false)
        #expect(entries[0].resumable == true)
    }

    @Test("downloaded entries sort before not-downloaded, larger first")
    func sortingDownloadedFirst() {
        let a = model("org/a-small-dl", sizeGb: 4, minRamGb: 8)
        let b = model("org/b-big-dl", sizeGb: 40, minRamGb: 8)
        let c = model("org/c-avail", sizeGb: 20, minRamGb: 8)
        let entries = Start.buildPickerEntries(
            rows: [row(a), row(b), row(c)],
            downloadedIDs: ["org/a-small-dl", "org/b-big-dl"],
            localMemoryByID: ["org/a-small-dl": 4, "org/b-big-dl": 40],
            resumableIDs: [],
            memoryGb: 64
        )
        #expect(entries.map(\.id) == ["org/b-big-dl", "org/a-small-dl", "org/c-avail"])
        #expect(entries.prefix(2).allSatisfy { $0.downloaded })
        #expect(entries.last?.downloaded == false)
    }
}
