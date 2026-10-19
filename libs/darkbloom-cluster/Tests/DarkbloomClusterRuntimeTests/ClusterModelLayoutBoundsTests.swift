import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Testing

@Suite("Placement inventory bounds and byte conservation")
struct ClusterModelLayoutBoundsTests {
    /// A two-layer metadata family exercises the real builder without model
    /// construction or an artifact-sized parameter inventory.
    private final class Family: ClusterPlacementFamily {
        let runtimeModelID = "inventory-limit-fixture"
        let layerCount = 2
        var admittedCuts = [1]
        let structuralCuts = [1]
        let generationModes: [ClusterGenerationMode] = [.pipeline]
        let prefillSchedules: [ClusterPrefillSchedule] = [.serial]
        let maximumPromptTokens = 16, maximumOutputTokens = 4, maximumChunkTokens = 4
        let boundaryBytesPerToken = 8
        var loadedOverride: Int?
        var work = 0
        var replicateEmbedding = false
        var stageCalls = 0

        func layer(ofStoredTensor name: String) -> Int? {
            if name.hasPrefix("0.") { return 0 }
            if name.hasPrefix("1.") { return 1 }
            return nil
        }
        func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
            stageCalls += 1
            if name == "embed" { return 0 }
            guard let layer = layer(ofStoredTensor: name) else {
                throw ClusterPlacementError("Unknown fixture tensor")
            }
            return layer < cut ? 0 : 1
        }
        func layerKind(_ layer: Int) -> String { "fixture" }
        func requestState(layer: Int) throws -> ClusterPlacementLayerState {
            .init(fixedBytes: 0, bytesPerToken: 0)
        }
        func loadedBytes(ofStoredTensor name: String, storedBytes: Int) -> Int { loadedOverride ?? storedBytes }
        func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int { work }
        func loadsAtBothEnds(storedTensor name: String) -> Bool { replicateEmbedding && name == "embed" }
    }

    private func tensors(_ count: Int) -> [ClusterPlacementStoredTensor] {
        (0..<count).map { .init(name: "\($0 % 2).\($0)", byteCount: 4, dtype: "F32", shape: [1]) }
    }

    private func build(_ tensors: [ClusterPlacementStoredTensor], family: Family = Family()) throws -> ClusterModelLayout {
        try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
            artifactSHA256: "", configurationSHA256: "")
    }

    @Test(arguments: [114_160, 200_000])
    func largeBoundedInventoryConservesBothLayers(count: Int) throws {
        let family = Family()
        let layout = try build(tensors(count), family: family)
        #expect(layout.layers.map { $0.weights.tensorCount } == [count / 2, count / 2])
        #expect(layout.layers.reduce(0) { $0 + $1.weights.storedBytes } == count * 4)
        #expect(layout.wholeModelLoadedBytes == count * 4)
        #expect(family.stageCalls == count)
        #expect(layout.range(0..<1).loadedBytes == count * 2)
        #expect(layout.range(1..<2).loadedBytes == count * 2)
    }

    @Test func oversizedInventoryIsRejectedBeforeFamilyEvaluation() throws {
        let family = Family()
        #expect(throws: ClusterPlacementError.self) { try build(tensors(200_001), family: family) }
        #expect(family.stageCalls == 0)
    }

    @Test func existingDistinctPositiveAndCutRequirementsRemainClosed() throws {
        #expect(throws: ClusterPlacementError.self) { try build([]) }
        #expect(throws: ClusterPlacementError.self) { try build([tensors(2)[0], tensors(2)[0]]) }
        for bytes in [0, -1] {
            #expect(throws: ClusterPlacementError.self) {
                try build([.init(name: "0.a", byteCount: bytes), .init(name: "1.a", byteCount: 4)])
            }
        }
        let family = Family()
        family.admittedCuts = [2]
        #expect(throws: ClusterPlacementError.self) { try build(tensors(2), family: family) }
        #expect(family.stageCalls == 0)
        #expect(throws: ClusterPlacementError.self) {
            try build(tensors(2) + [.init(name: "unknown", byteCount: 4)])
        }
    }

    @Test(arguments: ["stored", "loaded", "work", "replica"])
    func aggregateOverflowThrowsBeforePartitionArithmetic(kind: String) throws {
        let family = Family()
        var inputs = tensors(2)
        switch kind {
        case "stored": inputs = [.init(name: "0.a", byteCount: Int.max), .init(name: "1.a", byteCount: 1)]
        case "loaded": family.loadedOverride = Int.max
        case "work": family.work = Int.max
        default:
            family.loadedOverride = Int.max / 2 + 1
            family.replicateEmbedding = true
            inputs.insert(.init(name: "embed", byteCount: 4), at: 0)
        }
        #expect(throws: ClusterPlacementError.self) { try build(inputs, family: family) }
    }
}
