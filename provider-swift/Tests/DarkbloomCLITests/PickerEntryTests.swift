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
