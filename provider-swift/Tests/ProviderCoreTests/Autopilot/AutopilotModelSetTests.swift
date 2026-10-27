import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot model set")
struct AutopilotModelSetTests {
    @Test func reportableIDsAreBoundedVisibleASCII() {
        #expect(AutopilotModelSet.isReportableID("org/gpt-oss-20b-mlx_4bit"))
        #expect(AutopilotModelSet.isReportableID(String(repeating: "a", count: 256)))
        for id in ["", " leading", "tab\tinside", "nul\u{0}", "line\nbreak", "modèle",
                   String(repeating: "a", count: 257)] {
            #expect(AutopilotModelSet.isReportableID(id) == false, "\(id.debugDescription)")
        }
    }

    @Test func persistedSelectionComesFirstAndTheUnionIsCappedAndSorted() {
        #expect(AutopilotModelSet.effective(selected: ["b", "a"], cached: ["c", "a", "bad id"]) == ["a", "b", "c"])
        // The persisted selection survives the cap; cached builds fill the rest in ID order.
        let selected = (0..<250).map { "saved-\(String(format: "%03d", $0))" }
        let cached = (0..<10).map { "cached-\($0)" }
        let set = AutopilotModelSet.effective(selected: selected, cached: cached)
        #expect(set.count == AutopilotModelSet.maximumCount)
        #expect(Set(selected).isSubset(of: Set(set)))
        #expect(Set(set).subtracting(selected) == Set((0..<6).map { "cached-\($0)" }))
        #expect(set == set.sorted())
    }
}

@Suite("Autopilot build eligibility")
struct AutopilotBuildEligibilityTests {
    static let hash = String(repeating: "c", count: 64)

    static func entry(_ id: String = "net/model", active: Bool? = true, minRamGb: Int? = 16,
                      weightHash: String? = hash, aggregate: String? = nil,
                      requires: [ProviderRuntimeCapability]? = nil) -> CatalogModel {
        CatalogModel(id: id, s3Name: id, displayName: id, sizeGb: 4, minRamGb: minRamGb, active: active,
            weightHash: weightHash, r2Prefix: "v2/\(id)", aggregateSHA256: aggregate,
            requiredProviderCapabilities: requires)
    }

    static func local(_ id: String = "net/model", type: String = "gpt_oss", memoryGb: Double = 4,
                      hash: String? = nil) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1 << 30, estimatedMemoryGb: memoryGb, weightHash: hash)
    }

    @Test func catalogGatesMirrorThePickerDefaultSelection() {
        #expect(AutopilotBuildEligibility.catalogAllows(Self.entry(), memoryGb: 64, runtimeCapabilities: []))
        #expect(AutopilotBuildEligibility.catalogAllows(Self.entry(active: nil), memoryGb: 64, runtimeCapabilities: []))
        #expect(!AutopilotBuildEligibility.catalogAllows(Self.entry(active: false), memoryGb: 64, runtimeCapabilities: []))
        #expect(!AutopilotBuildEligibility.catalogAllows(Self.entry(minRamGb: 128), memoryGb: 64, runtimeCapabilities: []))
        let unmet = ProviderRuntimeCapability.appleM5
        #expect(!AutopilotBuildEligibility.catalogAllows(Self.entry(requires: [unmet]), memoryGb: 64,
            runtimeCapabilities: []))
        #expect(AutopilotBuildEligibility.catalogAllows(Self.entry(requires: [unmet]), memoryGb: 64,
            runtimeCapabilities: [unmet]))
    }

    @Test func aCachedBuildNeedsASupportedEngineAndTheLoadBudget() {
        let entry = Self.entry()
        #expect(AutopilotBuildEligibility.allowsCachedBuild(Self.local(), entry: entry, memoryGb: 64, runtimeCapabilities: []))
        #expect(!AutopilotBuildEligibility.allowsCachedBuild(Self.local(type: "not_a_family"), entry: entry,
            memoryGb: 64, runtimeCapabilities: []))
        #expect(!AutopilotBuildEligibility.allowsCachedBuild(Self.local(memoryGb: 200), entry: entry,
            memoryGb: 64, runtimeCapabilities: []))
        #expect(!AutopilotBuildEligibility.allowsCachedBuild(Self.local("other/model"), entry: entry,
            memoryGb: 64, runtimeCapabilities: []))
        // The scanned build's own gates, used without a catalog entry by the
        // start path's recorded downloads and by download publication.
        #expect(AutopilotBuildEligibility.allowsScannedBuild(Self.local(), memoryGb: 64))
        #expect(!AutopilotBuildEligibility.allowsScannedBuild(Self.local(type: "not_a_family"), memoryGb: 64))
        #expect(!AutopilotBuildEligibility.allowsScannedBuild(Self.local(memoryGb: 200), memoryGb: 64))
        #expect(AutopilotBuildEligibility.loadBudgetGiB(memoryGb: .nan) == 0)
    }

    @Test func onlyTheCatalogsCurrentBytesAreVerified() {
        #expect(AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: Self.hash, entry: Self.entry()))
        #expect(AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: Self.hash.uppercased(), entry: Self.entry()))
        let aggregate = String(repeating: "d", count: 64)
        #expect(AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: aggregate,
            entry: Self.entry(weightHash: nil, aggregate: aggregate)))
        #expect(!AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: "stale", entry: Self.entry()))
        #expect(!AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: nil, entry: Self.entry()))
        #expect(!AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: "",
            entry: Self.entry(weightHash: "", aggregate: "")))
    }
}

@Suite("Autopilot start inventory")
struct AutopilotStartInventoryTests {
    private typealias E = AutopilotBuildEligibilityTests
    private let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
        selectedModels: ["saved/model"], revision: "r1")

    private func start(catalog: [CatalogModel]?, recorded: [String: String] = [:],
                       settings: ModelAutopilotSettings? = nil) -> AutopilotStartInventory {
        AutopilotStartInventory(settings: settings ?? self.settings, catalog: catalog, recordedDownloads: recorded,
            memoryGb: 64, runtimeCapabilities: [])
    }

    @Test func everyVerifiedCurrentCatalogBuildJoinsThePersistedSelection() {
        let catalog = [E.entry("net/current"), E.entry("net/stale"), E.entry("net/inactive", active: false),
                       E.entry("net/unhashed")]
        let local = [E.local("saved/model", hash: "anything"), E.local("net/current", hash: E.hash),
                     E.local("net/stale", hash: "old-bytes"), E.local("net/inactive", hash: E.hash),
                     E.local("off/catalog", hash: E.hash), E.local("net/unhashed")]
        let start = start(catalog: catalog)
        #expect(local.filter(start.isCandidate).map(\.id)
            == ["saved/model", "net/current", "net/stale", "net/unhashed"])
        #expect(start.inventory(from: local).map(\.id) == ["saved/model", "net/current"])
    }

    @Test func withoutTheCatalogOnlyUnchangedRecordedDownloadsJoin() {
        let local = [E.local("saved/model", hash: "h0"), E.local("net/downloaded", hash: E.hash),
                     E.local("net/changed", hash: "rewritten"), E.local("net/unrecorded", hash: E.hash)]
        let start = start(catalog: nil, recorded: ["net/downloaded": E.hash, "net/changed": "verified"])
        #expect(start.inventory(from: local).map(\.id) == ["saved/model", "net/downloaded"])
        // With the catalog, it alone decides: a recorded build that is no
        // longer current leaves the set.
        let current = self.start(catalog: [E.entry("net/changed", weightHash: "rewritten")],
            recorded: ["net/downloaded": E.hash])
        #expect(current.inventory(from: local).map(\.id) == ["saved/model", "net/changed"])
    }

    @Test func withoutConsentNothingIsACandidate() {
        let start = start(catalog: [E.entry()], settings: .init())
        #expect(start.isCandidate(E.local(hash: E.hash)) == false)
        #expect(start.inventory(from: [E.local(hash: E.hash)]).isEmpty)
    }
}

@Suite("Autopilot download ledger and disk guard")
struct AutopilotDownloadLedgerTests {
    @Test func theLedgerRoundTripsBoundedValidEntriesWithOwnerOnlyAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = AutopilotDownloadLedger.url(configDirectory: directory)
        #expect(AutopilotDownloadLedger.read(from: url).downloads.isEmpty)

        var ledger = AutopilotDownloadLedger()
        ledger.record(.init(modelId: "net/a", weightHash: "h1", downloadedAtMs: 1))
        ledger.record(.init(modelId: "bad id", weightHash: "h", downloadedAtMs: 2))
        ledger.record(.init(modelId: "net/b", weightHash: "", downloadedAtMs: 3))
        ledger.record(.init(modelId: "net/a", weightHash: "h2", downloadedAtMs: 4))
        try ledger.write(to: url)
        let read = AutopilotDownloadLedger.read(from: url)
        #expect(read == ledger)
        #expect(read.weightHashes == ["net/a": "h2"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        for index in 0..<(AutopilotDownloadLedger.maximumEntries + 5) {
            ledger.record(.init(modelId: "net/m\(index)", weightHash: "h", downloadedAtMs: Int64(index)))
        }
        #expect(ledger.downloads.count == AutopilotDownloadLedger.maximumEntries)
        #expect(ledger.downloads.first?.modelId == "net/m5")

        try Data("not json".utf8).write(to: url)
        #expect(AutopilotDownloadLedger.read(from: url).downloads.isEmpty)
    }

    @Test func theDiskGuardKeepsTheReserveAndFailsClosed() {
        let gib: Int64 = 1 << 30
        #expect(AutopilotDownloadSettings().reserveBytes == 50 * gib)
        #expect(AutopilotDownloadSettings(reserveGb: 0).reserveBytes == 0)
        #expect(AutopilotDiskGuard.bytes(gib: .max) == .max)
        #expect(AutopilotDiskGuard.allows(neededBytes: 10 * gib, freeBytes: 60 * gib, reserveBytes: 50 * gib))
        #expect(!AutopilotDiskGuard.allows(neededBytes: 10 * gib + 1, freeBytes: 60 * gib, reserveBytes: 50 * gib))
        #expect(!AutopilotDiskGuard.allows(neededBytes: 0, freeBytes: nil, reserveBytes: 0))
        #expect(!AutopilotDiskGuard.allows(neededBytes: .max, freeBytes: .max, reserveBytes: 1))
        #expect(AutopilotDiskGuard.volumeFreeBytes(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/deeper")).map { $0 > 0 } == true)
    }

    @Test func downloadsAreOnByDefaultAndProviderConfigurationOutsideConsent() throws {
        var backend = BackendSettings()
        #expect(backend.autopilotDownloads == nil)
        let encoded = try JSONEncoder().encode(backend)
        #expect(String(decoding: encoded, as: UTF8.self).contains("autopilot_downloads") == false)
        // No table, or a table with no `enabled` key, means on; absent limits
        // encode as absent.
        #expect(AutopilotDownloadSettings().enabled)
        let table = try JSONDecoder().decode(AutopilotDownloadSettings.self, from: Data(#"{"max_models":2}"#.utf8))
        #expect(table == AutopilotDownloadSettings(enabled: true, maxModels: 2))
        #expect(try JSONDecoder().decode(AutopilotDownloadSettings.self, from: Data(#"{"enabled":false}"#.utf8))
            == AutopilotDownloadSettings(enabled: false))
        #expect(String(decoding: try JSONEncoder().encode(AutopilotDownloadSettings(enabled: true)), as: UTF8.self)
            == #"{"enabled":true}"#)
        backend.autopilotDownloads = .init(enabled: true, maxStorageGb: 200, maxModels: 3)
        let decoded = try JSONDecoder().decode(BackendSettings.self, from: JSONEncoder().encode(backend))
        #expect(decoded.autopilotDownloads == backend.autopilotDownloads)
        #expect(decoded.modelAutopilot == backend.modelAutopilot)
        // The TOML file round-trips the table under [backend].
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "downloads"))
        config.backend.autopilotDownloads = backend.autopilotDownloads
        try ConfigManager.save(config, to: path)
        #expect(try ConfigManager.load(from: path).backend.autopilotDownloads == backend.autopilotDownloads)
        #expect(try String(contentsOf: path, encoding: .utf8).contains("[backend.autopilot_downloads]"))
    }

    @Test func theBudgetRefusesAtEachCapAndAtTheReserve() {
        let gib: Int64 = 1 << 30
        var budget = AutopilotDownloadBudget(freeBytes: 100 * gib, reserveBytes: 50 * gib, usedBytes: 20 * gib,
            usedModels: 2, limitBytes: 40 * gib, limitModels: 3)
        #expect(budget.refusalBeforeSizing == nil)
        #expect(budget.refusal(neededBytes: 20 * gib) == nil)
        #expect(budget.refusal(neededBytes: 20 * gib + 1) == .storageLimitReached)
        budget.limitBytes = nil
        #expect(budget.refusal(neededBytes: 50 * gib) == nil)
        #expect(budget.refusal(neededBytes: 50 * gib + 1) == .insufficientDisk)
        budget.usedModels = 3
        #expect(budget.refusalBeforeSizing == .modelLimitReached)
        budget = .init(freeBytes: 100 * gib, reserveBytes: 0, usedBytes: 40 * gib, usedModels: 0, limitBytes: 40 * gib)
        #expect(budget.refusalBeforeSizing == .storageLimitReached)
        budget = .init(freeBytes: nil, reserveBytes: 0, usedBytes: 0, usedModels: 0)
        #expect(budget.refusal(neededBytes: 0) == .insufficientDisk)
        #expect(budget.report == ModelAutopilotDownloadStorage(diskFreeBytes: 0, reserveBytes: 0, usedBytes: 0, usedModels: 0))
        budget = .init(freeBytes: .max, reserveBytes: 0, usedBytes: .max, usedModels: 0, limitBytes: .max)
        #expect(budget.refusal(neededBytes: 1) == .storageLimitReached)
    }

    @Test func usageCountsOnlyRecordedBuildsStillOnDisk() {
        var ledger = AutopilotDownloadLedger()
        ledger.record(.init(modelId: "net/a", weightHash: "h", downloadedAtMs: 1, sizeBytes: 10))
        ledger.record(.init(modelId: "net/b", weightHash: "h", downloadedAtMs: 2, sizeBytes: 20))
        ledger.record(.init(modelId: "net/gone", weightHash: "h", downloadedAtMs: 3, sizeBytes: 40))
        let onDisk: (String) -> Bool = { $0 != "net/gone" }
        #expect(ledger.usage(onDisk: onDisk) == (bytes: 30, models: 2))
        #expect(ledger.usage(excluding: "net/b", onDisk: onDisk) == (bytes: 10, models: 1))
    }
}

@Suite("Autopilot download prefetcher")
struct AutopilotDownloadPrefetcherTests {
    private typealias E = AutopilotBuildEligibilityTests

    private static let manifest = ModelManifest(schemaVersion: 1, modelID: "net/model", version: "1",
        r2Prefix: "v2/net/model", aggregateSHA256: String(repeating: "a", count: 64), totalSizeBytes: 4 << 30,
        fileCount: 1, files: [], createdAt: Date(timeIntervalSince1970: 0))

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var downloads = 0
        func downloaded() { lock.withLock { downloads += 1 } }
        var count: Int { lock.withLock { downloads } }
    }

    private func prefetcher(catalog: @escaping @Sendable () async throws -> [CatalogModel] = { [E.entry(aggregate: "a")] },
                            manifest: @escaping @Sendable (CatalogModel) async throws -> ModelManifest = { _ in Self.manifest },
                            freeGiB: Int64? = 100, neededBytes: Int64 = 4 << 30,
                            usedGiB: Int64 = 0, limitGiB: Int64? = nil,
                            download: @escaping @Sendable () async throws -> Void = {},
                            calls: Calls = Calls()) -> AutopilotDownloadPrefetcher {
        AutopilotDownloadPrefetcher(memoryGb: 64, runtimeCapabilities: [],
            dependencies: .init(catalog: catalog, manifest: manifest, neededBytes: { _, _ in neededBytes },
                budget: { _ in AutopilotDownloadBudget(freeBytes: freeGiB.map { $0 << 30 }, reserveBytes: 50 << 30,
                    usedBytes: usedGiB << 30, usedModels: 0, limitBytes: limitGiB.map { $0 << 30 }) },
                download: { _, _, progress in
                    calls.downloaded()
                    try await download()
                    progress(4 << 30, 4 << 30)
                },
                log: { _ in }))
    }

    private func refusal(_ prefetcher: AutopilotDownloadPrefetcher, model: String = "net/model") async -> String? {
        do {
            try await prefetcher.prefetchToDisk(modelID: model) { _, _ in }
            return nil
        } catch { return error.localizedDescription }
    }

    @Test func refusalsUseTheClosedVocabulary() async {
        struct Offline: Error {}
        #expect(await refusal(prefetcher(catalog: { throw Offline() })) == "catalog_unavailable")
        #expect(await refusal(prefetcher(), model: "net/unknown") == "model_not_supported")
        #expect(await refusal(prefetcher(catalog: { [E.entry(active: false, aggregate: "a")] })) == "model_not_supported")
        #expect(await refusal(prefetcher(catalog: { [E.entry(minRamGb: 512, aggregate: "a")] })) == "model_not_supported")
        // No manifest to verify against: not downloadable.
        #expect(await refusal(prefetcher(catalog: { [E.entry(aggregate: nil)] })) == "model_not_supported")
        #expect(await refusal(prefetcher(manifest: { _ in throw Offline() })) == "catalog_unavailable")
        #expect(await refusal(prefetcher(freeGiB: 53)) == "insufficient_disk")
        #expect(await refusal(prefetcher(freeGiB: nil)) == "insufficient_disk")
        #expect(await refusal(prefetcher(download: { throw Offline() })) == "download_failed")
        // The operator's storage cap counts the build being fetched.
        #expect(await refusal(prefetcher(usedGiB: 7, limitGiB: 10)) == "storage_limit_reached")
        #expect(await refusal(prefetcher(usedGiB: 6, limitGiB: 10)) == nil)
        #expect(Set(AutopilotDownloadRefusal.allCases.map(\.rawValue)) == ["autopilot_paused", "model_not_supported",
            "insufficient_disk", "storage_limit_reached", "model_limit_reached", "catalog_unavailable",
            "download_failed"])
    }

    @Test func aGuardedDownloadRunsOnceAndAPresentRevisionNeedsNoRoom() async {
        let calls = Calls()
        #expect(await refusal(prefetcher(freeGiB: 54, calls: calls)) == nil)
        #expect(calls.count == 1)
        let present = Calls()
        #expect(await refusal(prefetcher(freeGiB: 51, neededBytes: 0, calls: present)) == nil)
        #expect(present.count == 1)
        let refused = Calls()
        #expect(await refusal(prefetcher(freeGiB: 53, calls: refused)) == "insufficient_disk")
        #expect(refused.count == 0)
    }

    @Test func cancellationIsNotARefusal() async {
        let task = Task { () -> Error? in
            do {
                try await prefetcher(download: { throw CancellationError() }).prefetchToDisk(modelID: "net/model") { _, _ in }
                return nil
            } catch { return error }
        }
        #expect(await task.value is CancellationError)
    }
}
