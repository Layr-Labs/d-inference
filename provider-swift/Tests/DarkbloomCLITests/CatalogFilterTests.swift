import Foundation
import Testing
import ProviderCore
@testable import darkbloom

/// Tests for the catalog-only model discovery gate: only coordinator-catalog
/// models may be advertised, served, or diagnosed.
@Suite struct CatalogFilterTests {
    private func makeModel(id: String) -> ModelInfo {
        ModelInfo(
            id: id,
            modelType: "text",
            parameters: nil,
            quantization: nil,
            sizeBytes: 1_000_000,
            estimatedMemoryGb: 1.0,
            weightHash: nil,
            isVision: nil,
            templateRenderOK: nil
        )
    }

    private func makeCatalog(ids: [String]) -> CatalogSnapshot {
        CatalogSnapshot(models: ids.map { id in
            CatalogModel(
                id: id,
                s3Name: id,
                displayName: id,
                modelType: "text",
                sizeGb: 1.0
            )
        })
    }

    @Test func catalogFilteredModels_keepsCatalogModels() {
        let local = [makeModel(id: "supported-a"), makeModel(id: "supported-b")]
        let catalog = makeCatalog(ids: ["supported-a", "supported-b"])
        let filtered = catalogFilteredModels(local, catalog: catalog)
        #expect(filtered.map({ $0.id }) == ["supported-a", "supported-b"])
    }

    @Test func catalogFilteredModels_dropsNonCatalogModels() {
        let local = [makeModel(id: "supported"), makeModel(id: "unsupported")]
        let catalog = makeCatalog(ids: ["supported"])
        let filtered = catalogFilteredModels(local, catalog: catalog)
        #expect(filtered.map({ $0.id }) == ["supported"])
    }

    @Test func catalogFilteredModels_failsClosedWithoutCatalog() {
        let local = [makeModel(id: "supported")]
        let filtered = catalogFilteredModels(local, catalog: nil)
        #expect(filtered.isEmpty)
    }

    @Test func advertisedModels_appliesCatalogFilterBeforeEnabledList() {
        let local = [
            makeModel(id: "supported-a"),
            makeModel(id: "supported-b"),
            makeModel(id: "unsupported")
        ]
        let catalog = makeCatalog(ids: ["supported-a", "supported-b"])
        var config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,1",
            chipName: "Apple M1",
            chipFamily: .m1,
            chipTier: .base,
            memoryGb: 16,
            memoryAvailableGb: 12,
            cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
            gpuCores: 8,
            memoryBandwidthGbs: 50
        ))
        config.backend.enabledModels = ["supported-a"]

        let advertised = advertisedModels(from: local, config: config, catalog: catalog)
        #expect(advertised.map({ $0.id }) == ["supported-a"])
    }

    @Test func advertisedModels_modelOverridesAreFilteredByCatalog() {
        let local = [
            makeModel(id: "supported"),
            makeModel(id: "unsupported")
        ]
        let catalog = makeCatalog(ids: ["supported"])
        let config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,1",
            chipName: "Apple M1",
            chipFamily: .m1,
            chipTier: .base,
            memoryGb: 16,
            memoryAvailableGb: 12,
            cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
            gpuCores: 8,
            memoryBandwidthGbs: 50
        ))

        let advertised = advertisedModels(
            from: local,
            config: config,
            catalog: catalog,
            modelOverrides: ["supported", "unsupported"]
        )
        #expect(advertised.map({ $0.id }) == ["supported"])
    }

    @Test func localAdvertisedModels_bypassesCatalogFilter() {
        let local = [
            makeModel(id: "supported"),
            makeModel(id: "unsupported")
        ]
        let config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,1",
            chipName: "Apple M1",
            chipFamily: .m1,
            chipTier: .base,
            memoryGb: 16,
            memoryAvailableGb: 12,
            cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
            gpuCores: 8,
            memoryBandwidthGbs: 50
        ))

        let advertised = localAdvertisedModels(from: local, config: config)
        #expect(advertised.map({ $0.id }) == ["supported", "unsupported"])
    }

    @Test func localAdvertisedModels_honorsEnabledModels() {
        let local = [
            makeModel(id: "enabled"),
            makeModel(id: "disabled")
        ]
        var config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,1",
            chipName: "Apple M1",
            chipFamily: .m1,
            chipTier: .base,
            memoryGb: 16,
            memoryAvailableGb: 12,
            cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
            gpuCores: 8,
            memoryBandwidthGbs: 50
        ))
        config.backend.enabledModels = ["enabled"]

        let advertised = localAdvertisedModels(from: local, config: config)
        #expect(advertised.map({ $0.id }) == ["enabled"])
    }

    @Test func localAdvertisedModels_honorsModelOverrides() {
        let local = [
            makeModel(id: "a"),
            makeModel(id: "b")
        ]
        let config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,1",
            chipName: "Apple M1",
            chipFamily: .m1,
            chipTier: .base,
            memoryGb: 16,
            memoryAvailableGb: 12,
            cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
            gpuCores: 8,
            memoryBandwidthGbs: 50
        ))

        let advertised = localAdvertisedModels(from: local, config: config, modelOverrides: ["b"])
        #expect(advertised.map({ $0.id }) == ["b"])
    }

    @Test func localAdvertisedModels_allFlagIgnoresEnabledList() {
        let local = [
            makeModel(id: "enabled"),
            makeModel(id: "disabled")
        ]
        var config = ProviderConfig.defaultForHardware(HardwareInfo(
            machineModel: "Mac16,1",
            chipName: "Apple M1",
            chipFamily: .m1,
            chipTier: .base,
            memoryGb: 16,
            memoryAvailableGb: 12,
            cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
            gpuCores: 8,
            memoryBandwidthGbs: 50
        ))
        config.backend.enabledModels = ["enabled"]

        let advertised = localAdvertisedModels(from: local, config: config, includeDisabled: true)
        #expect(advertised.map({ $0.id }) == ["enabled", "disabled"])
    }

    @Test func catalogAllowedIDs_includesModelsAndAliasLineage() {
        let catalog = CatalogSnapshot(
            models: [
                CatalogModel(id: "active-a", s3Name: "active-a", displayName: "Active A", modelType: "text", sizeGb: 1.0),
                CatalogModel(id: "active-b", s3Name: "active-b", displayName: "Active B", modelType: "text", sizeGb: 1.0)
            ],
            aliases: [
                CatalogAlias(
                    id: "alias-1",
                    displayName: "Alias 1",
                    desiredBuild: "active-a",
                    previousBuild: "previous-build",
                    retiredBuilds: ["retired-build"],
                    primaryBuild: nil
                )
            ]
        )
        let allowed = catalogAllowedIDs(catalog: catalog)
        #expect(allowed == Set(["active-a", "active-b", "previous-build", "retired-build"]))
    }

    @Test func catalogAllowedIDs_isEmptyWhenCatalogMissing() {
        #expect(catalogAllowedIDs(catalog: nil).isEmpty)
    }

    @Test func catalogCachePath_scopesByCoordinatorURL() {
        let prodPath = CatalogCache.path(for: "wss://api.darkbloom.dev/ws/provider")
        let stagingPath = CatalogCache.path(for: "wss://api.staging.darkbloom.dev/ws/provider")
        #expect(prodPath.lastPathComponent != stagingPath.lastPathComponent)
        #expect(prodPath.deletingLastPathComponent() == CatalogCache.defaultDirectory())
    }
}
