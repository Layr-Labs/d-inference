import MLX
import Testing

/// CPU-device replay of existing storage oracles. The ordinary suites remain
/// unchanged; these wrappers neither load model weights nor weaken assertions.
@Suite("CPU checkpoint acceptance", .serialized)
struct SSDCheckpointCPUAcceptanceTests {
    @Test("complete checkpoint lifecycle on CPU", arguments: [
        "miss", "restartTenant", "deduplicate", "allocationRefusal", "corruption",
        "captureBounds", "changedFile", "disabledExpired", "closeWriter",
        "overlappingStages", "crossModelBudget", "scratchRefusal",
    ])
    func lifecycle(_ scenario: String) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            let suite = SSDHybridCheckpointStoreTests()
            switch scenario {
            case "miss": try await suite.missDoesNotRead()
            case "restartTenant": try await suite.restartAndTenant()
            case "deduplicate": try await suite.repeatDeduplicates()
            case "allocationRefusal": try await suite.allocationFailureKeepsFile()
            case "corruption": try await suite.corruptionIsCold()
            case "captureBounds": try suite.captureEligibility()
            case "changedFile": try await suite.changedFileCannotUseReceiptProof()
            case "disabledExpired": try await suite.disabledAndExpiredAreCold()
            case "closeWriter": try await suite.closeDoesNotWaitOnWrite()
            case "overlappingStages": try await suite.overlappingStagesPreserveFile()
            case "crossModelBudget": try await suite.sharedDiskBudget()
            case "scratchRefusal": try await suite.engineScratchRefusalBeforeRead()
            default: Issue.record("unknown lifecycle scenario")
            }
            #expect(Device.defaultDevice().deviceType == .cpu)
        }
    }

    @Test("valid duplicate geometry on CPU", arguments: [false, true], [512, 2048])
    func duplicateGeometry(paged: Bool, storedChunkSize: Int) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            try await SSDHybridCheckpointDuplicateTests().differentChunkSizes(
                paged: paged, storedChunkSize: storedChunkSize)
            #expect(Device.defaultDevice().deviceType == .cpu)
        }
    }

    @Test("invalid duplicates still reject on CPU",
          arguments: SSDHybridCheckpointDuplicateTests.InvalidStoredCheckpoint.allCases)
    func duplicateFault(_ fault: SSDHybridCheckpointDuplicateTests.InvalidStoredCheckpoint) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            try await SSDHybridCheckpointDuplicateTests().invalidStoredCheckpoint(fault)
            #expect(Device.defaultDevice().deviceType == .cpu)
        }
    }

    @Test("shared process storage ownership on CPU", arguments: [
        "missingHostAuthority", "closeRetainsHost", "stageOwnership", "writeHostRefusal",
        "allocationRefusal", "unsharedDestination",
    ])
    func ownership(_ scenario: String) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            let suite = SSDSharedProcessCheckpointTests()
            switch scenario {
            case "missingHostAuthority": try await suite.missingHostAuthority()
            case "closeRetainsHost": try await suite.writeCloseRetainsHostOwner()
            case "stageOwnership": try await suite.stageOwnership()
            case "writeHostRefusal": try await suite.writeHostRefusal()
            case "allocationRefusal": try await suite.allocationFailure()
            case "unsharedDestination": try await suite.nonsharedActualDestination()
            default: Issue.record("unknown ownership scenario")
            }
            #expect(Device.defaultDevice().deviceType == .cpu)
        }
    }

    @Test("whole-root telemetry remains available on CPU")
    func telemetry() async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            try await SSDWholeRootTelemetryConcurrencyTests().snapshotDoesNotWaitForSweep()
            #expect(Device.defaultDevice().deviceType == .cpu)
        }
    }
}
