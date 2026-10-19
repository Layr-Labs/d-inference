import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM stage ownership and bounded metadata, no model or payload")
struct GLM5NextStageMetadataTests {
    @Test func allFortyFourCutsConserveSourcesAndPriceOnlyTheMTPEmbeddingReplica() throws {
        let f = try GLM5NextMetadataTestFixture()
        let layout = try GLM5NextStageLayout(inventory: f.validate())
        #expect(layout.layers.map(\.globalIndex) == Array(0..<45))
        #expect(layout.structuralCuts == Array(1..<45))
        #expect(layout.admittedCuts.isEmpty)
        #expect(layout.layers.filter { $0.attention == "deepseek_sparse_attention" }.map(\.globalIndex)
            == Array(stride(from: 3, to: 45, by: 4)))
        #expect(layout.streamCount == 4 && layout.boundaryBytesPerToken == 4 * 4 * 4)
        let total = f.inventory.entries.values.reduce(0) { $0 + $1.bytes }
        #expect(layout.totalSource.bytes == total)
        #expect(layout.totalSource.tensorCount == f.inventory.entries.count)
        for includeMTP in [false, true] {
            let splits = try layout.allSplits(includeMTP: includeMTP)
            #expect(splits.count == 44)
            for split in splits {
                let first = split.stages[0], last = split.stages[1]
                #expect(first.globalLayers == 0..<split.cut)
                #expect(last.globalLayers == split.cut..<45)
                // Independent bounded layer sums check the prefix/suffix summaries.
                let firstLayers = layout.layers.prefix(split.cut).reduce(0) { $0 + $1.source.bytes }
                let lastLayers = layout.layers.dropFirst(split.cut).reduce(0) { $0 + $1.source.bytes }
                #expect(first.source.bytes == firstLayers + layout.embedding.bytes)
                #expect(last.source.bytes == lastLayers + layout.finalNorm.bytes + layout.head.bytes
                    + (includeMTP ? layout.mtp.bytes + layout.embedding.bytes : 0))
                #expect(first.source.bytes + last.source.bytes + split.excluded.bytes
                    == total + split.additionalMTPEmbedding.bytes)
                #expect(first.source.tensorCount + last.source.tensorCount + split.excluded.tensorCount
                    == layout.totalSource.tensorCount + split.additionalMTPEmbedding.tensorCount)
                #expect(split.additionalMTPEmbedding == (includeMTP ? layout.embedding : .empty))
                #expect(split.excluded.bytes == layout.vision.bytes + (includeMTP ? 0 : layout.mtp.bytes))
            }
        }
    }

    @Test func selectedSourcesKeepGlobalIndicesAndFinalReadoutAndVisionOwnership() throws {
        let f = try GLM5NextMetadataTestFixture()
        let layout = try GLM5NextStageLayout(inventory: f.inventory)
        let cut = 22
        let first = try layout.sourceNames(rank: 0, cut: cut, includeMTP: true)
        let last = try layout.sourceNames(rank: 1, cut: cut, includeMTP: true)
        let embedding = Set(f.inventory.entries.keys.filter { $0.hasPrefix("model.language_model.embed_tokens.") })
        let vision = Set(f.inventory.entries(in: .vision).map { $0.tensor.name })
        #expect(first.intersection(last) == embedding)
        #expect(first.union(last) == Set(f.inventory.entries.keys).subtracting(vision))
        for entry in f.inventory.entries(in: .mtp) {
            #expect(entry.tensor.name.hasPrefix("model.language_model.layers.45."))
            #expect(!first.contains(entry.tensor.name) && last.contains(entry.tensor.name))
            #expect(try layout.ranks(of: entry.tensor.name, cut: cut, includeMTP: false).isEmpty)
        }
        for name in ["model.language_model.norm.weight", "lm_head.weight"] {
            #expect(try layout.ranks(of: name, cut: cut, includeMTP: false) == [1])
        }
        for index in [0, 21, 22, 44] {
            let name = try #require(f.inventory.entries.keys.first { $0.hasPrefix("model.language_model.layers.\(index).") })
            #expect(try layout.sourceOwner(of: name) == .layer(index))
            #expect(try layout.ranks(of: name, cut: cut, includeMTP: true) == [index < cut ? 0 : 1])
        }
        for name in vision { #expect(try layout.ranks(of: name, cut: cut, includeMTP: true).isEmpty) }
        #expect(throws: ProbeError.self) { try layout.sourceOwner(of: "model.language_model.layers.045.enorm.weight") }
        #expect(throws: ProbeError.self) { try layout.sourceNames(rank: 2, cut: cut, includeMTP: true) }
        for invalid in [-1, 0, 45, Int.max] {
            #expect(throws: ProbeError.self) { try layout.split(at: invalid, includeMTP: true) }
        }
    }

    @Test func completeHeaderJoinUsesTheSDKSchemaAndReadsEachShardOnce() throws {
        let f = try GLM5NextMetadataTestFixture(layers: 4)
        var reads: [String] = []
        let actual = try GLM5NextHeaderInventory.validate(
            configuration: f.configuration, index: f.index, storage: .float32) { name in
                reads.append(name)
                return try #require(f.shards[name])
            }
        #expect(reads == ["a.safetensors", "b.safetensors"])
        #expect(GLM5NextArtifactMetadata.fingerprint(actual) == GLM5NextArtifactMetadata.fingerprint(f.inventory))
        #expect(actual.entries.count == f.inventory.entries.count)
        for entry in actual.entries.values {
            let expected = try #require(f.inventory.entries[entry.tensor.name])
            #expect(entry.tensor == expected.tensor && entry.bytes == expected.bytes && entry.part == expected.part)
        }
    }

    @Test(arguments: ["shape", "dtype", "offset", "missing", "duplicate", "fractionalOffset"])
    func malformedHeadersAreRefused(change: String) throws {
        let f = try GLM5NextMetadataTestFixture(layers: 4)
        let original = try #require(f.shards["a.safetensors"])
        var object = try #require(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
        let name = try #require(object.keys.sorted().first)
        var tensor = try #require(object[name] as? [String: Any])
        switch change {
        case "shape": tensor["shape"] = [1]
        case "dtype": tensor["dtype"] = "BF16"
        case "offset": tensor["data_offsets"] = [-1, 4]
        default: break
        }
        object[name] = tensor
        if change == "missing" { object.removeValue(forKey: name) }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if change == "duplicate" {
            let key = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
            let value = String(decoding: try JSONSerialization.data(withJSONObject: tensor), as: UTF8.self)
            data = Data(("{" + key + ":" + value + "," + String(decoding: data.dropFirst(), as: UTF8.self)).utf8)
        } else if change == "fractionalOffset" {
            data = Data(#"{"bad":{"dtype":"F32","shape":[1],"data_offsets":[0.0,4]}}"#.utf8)
        }
        var shards = f.shards
        shards["a.safetensors"] = .init(data: data,
            fileBytes: original.fileBytes - original.data.count + data.count)
        #expect(throws: (any Error).self) { try f.validate(shards: shards) }
    }

    @Test(arguments: ["missing", "wrongShard", "total", "unsafeShard"])
    func indexMustExactlyCoverHeaders(change: String) throws {
        let f = try GLM5NextMetadataTestFixture(layers: 4)
        var object = try #require(JSONSerialization.jsonObject(with: f.index) as? [String: Any])
        var map = try #require(object["weight_map"] as? [String: String])
        let name = try #require(map.keys.sorted().first)
        switch change {
        case "missing": map.removeValue(forKey: name)
        case "wrongShard": map[name] = map[name] == "a.safetensors" ? "b.safetensors" : "a.safetensors"
        case "unsafeShard": map[name] = "../a.safetensors"
        default: object["metadata"] = ["total_size": 1]
        }
        object["weight_map"] = map
        let changed = try JSONSerialization.data(withJSONObject: object)
        var reads = 0
        #expect(throws: (any Error).self) {
            try GLM5NextHeaderInventory.validate(configuration: f.configuration, index: changed, storage: .float32) {
                reads += 1
                return try #require(f.shards[$0])
            }
        }
        if change == "unsafeShard" { #expect(reads == 0) }
    }

    @Test func wrongArtifactPinsAndUnaccountedFileBytesAreRefused() throws {
        let f = try GLM5NextMetadataTestFixture(layers: 4)
        var reads = 0
        #expect(throws: ProbeError.self) {
            try GLM5NextArtifactMetadata(configuration: JSONEncoder().encode(f.configuration), index: f.index) { name in
                reads += 1
                return try #require(f.shards[name])
            }
        }
        #expect(reads == 0)
        var trailing = f.shards
        let shard = try #require(trailing["a.safetensors"])
        trailing["a.safetensors"] = .init(data: shard.data, fileBytes: shard.fileBytes + 1)
        #expect(throws: ProbeError.self) { try f.validate(shards: trailing) }
        trailing["a.safetensors"] = .init(data: shard.data, fileBytes: shard.data.count + 7)
        #expect(throws: ProbeError.self) { try f.validate(shards: trailing) }
    }

    /// Opt-in metadata gate for the parent's verified external artifact. No
    /// tensor payload reads or native execution, even when explicitly enabled.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_DIRECTORY"] != nil))
    func eigenLabs8841HeadersMatchExactPinsAndAllStructuralCuts() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_DIRECTORY"])
        let metadata = try GLM5NextArtifactMetadata.read(directory: URL(fileURLWithPath: path))
        let layout = metadata.layout
        #expect(metadata.inventory.storage == .nvfp4Hybrid)
        #expect(layout.totalSource.tensorCount == 114_160 && layout.totalSource.bytes == 181_693_841_436)
        #expect(layout.layers.count == 45 && layout.structuralCuts == Array(1..<45))
        #expect(layout.admittedCuts.isEmpty && layout.declaredMaximumPositions == 1_048_576)
        #expect(layout.boundaryDType == "bfloat16" && layout.hiddenSize == 4096 && layout.streamCount == 4)
        #expect(layout.boundaryBytesPerToken == 32_768)
        #expect(layout.embedding.bytes == 356_843_520 && layout.embedding.tensorCount == 3)
        #expect(layout.finalNorm.bytes + layout.head.bytes == 356_851_712)
        #expect(layout.mtp.bytes == 4_183_320_576 && layout.mtp.tensorCount == 2641)
        #expect(layout.vision.bytes == 1_127_254_016 && layout.vision.tensorCount == 347)
        for split in try layout.allSplits(includeMTP: true) {
            #expect(split.stages.reduce(0) { $0 + $1.source.bytes } == 180_923_430_940)
            #expect(split.excluded == layout.vision)
            #expect(split.additionalMTPEmbedding == layout.embedding)
        }
    }
}
