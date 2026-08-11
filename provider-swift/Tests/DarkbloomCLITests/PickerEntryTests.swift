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

    private func model(_ id: String, sizeGb: Double = 10, minRamGb: Int? = nil) -> CatalogModel {
        CatalogModel(
            id: id,
            s3Name: id,
            displayName: id,
            sizeGb: sizeGb,
            minRamGb: minRamGb,
            r2Prefix: "v2/\(id)/v1"
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

    // MARK: - resolveFallbackSelection (non-TTY picker won't-fit guard)

    @Test("fallback 'all' selects only models that fit in RAM")
    func fallbackAllExcludesWontFit() {
        let small = entry("org/small", sizeGb: 8)
        let huge = entry("org/huge", sizeGb: 200)
        // 14 GB per-model budget (18 GB box − 4 GB reserve): small fits, huge does not.
        let r = Start.resolveFallbackSelection(input: "all", entries: [small, huge], budgetGb: 14)
        #expect(r == .selected(["org/small"]))
    }

    @Test("fallback rejects an explicit won't-fit pick instead of serving it")
    func fallbackRejectsWontFitIndex() {
        let small = entry("org/small", sizeGb: 8)
        let huge = entry("org/huge", sizeGb: 200)
        guard case .rejected = Start.resolveFallbackSelection(input: "2", entries: [small, huge], budgetGb: 14) else {
            Issue.record("expected a won't-fit explicit selection to be rejected")
            return
        }
    }

    @Test("fallback selects explicit fitting models in order")
    func fallbackSelectsFitting() {
        let small = entry("org/small", sizeGb: 8)
        let mid = entry("org/mid", sizeGb: 12)
        #expect(
            Start.resolveFallbackSelection(input: "1,2", entries: [small, mid], budgetGb: 14)
                == .selected(["org/small", "org/mid"]))
    }

    @Test("fallback rejects 'all' when nothing fits")
    func fallbackRejectsAllTooBig() {
        let huge = entry("org/huge", sizeGb: 200)
        guard case .rejected = Start.resolveFallbackSelection(input: "all", entries: [huge], budgetGb: 14) else {
            Issue.record("expected rejection when no model fits")
            return
        }
    }

    @Test("fallback empty input cancels, out-of-range and non-numeric are rejected")
    func fallbackEmptyAndRange() {
        let small = entry("org/small", sizeGb: 8)
        #expect(Start.resolveFallbackSelection(input: "", entries: [small], budgetGb: 14) == .cancelled)
        #expect(Start.resolveFallbackSelection(input: "   ", entries: [small], budgetGb: 14) == .cancelled)
        guard case .rejected = Start.resolveFallbackSelection(input: "5", entries: [small], budgetGb: 14) else {
            Issue.record("expected out-of-range rejection")
            return
        }
        guard case .rejected = Start.resolveFallbackSelection(input: "x", entries: [small], budgetGb: 14) else {
            Issue.record("expected non-numeric rejection")
            return
        }
    }

    @Test("picker budget under a limit is the load bound, not limit minus 4")
    func pickerBudgetUnderLimitUsesLoadBound() {
        let gib: UInt64 = 1_073_741_824
        // 256 GB box, 150 GB limit: budget = cap − load headroom, NOT 146.
        let capped = ProviderSettings(name: "t", memoryReserveGB: 4, memoryLimitGB: 150)
        let expected = Double(150 * gib - UnifiedMemoryCap.loadHeadroomBytes()) / Double(gib)
        #expect(Start.pickerFitBudgetGb(physicalGb: 256, provider: capped) == expected)
        #expect(expected < 146)
        // Uncapped: historical physical − 4.
        let uncapped = ProviderSettings(name: "t", memoryReserveGB: 4)
        #expect(Start.pickerFitBudgetGb(physicalGb: 256, provider: uncapped) == 252)
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
