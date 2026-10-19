import Darwin
import DarkbloomClusterPlacement
import Foundation
import MLXLLM

/// Immutable metadata observed for EigenLabs revision 8841. These are expected
/// identities, not proof of payload integrity, runtime admission or calibration.
/// The native receipt used the older `4bit-mtp` repository label; the manifest
/// and selection use `NVFP4-mtp`. Config/index hashes identify the same bytes.
enum GLM5NextArtifactPin {
    static let repository = "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp"
    static let revision = "8841c52a1e8400bd7d3e7e631c916a6c4e6757b0"
    static let artifactSHA256 = "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac"
    static let configurationSHA256 = "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b"
    static let indexSHA256 = "b6cdec53a012ec4a8b383d37224f5955d463ec244d80b43d24fac72aa4c07b47"
    /// Same sorted `name|dtype|shape|bytes` format as ClusterPlacementInventory.
    static let inventorySHA256 = "47687e80512c9af7e8116f93dcea008c685efb2e3d3a83ff3d77e599c680611f"
    static let configurationBytes = 10_023_646
    static let indexBytes = 12_351_468
    static let tensorCount = 114_160
    static let shardCount = 35
    static let sourceBytes = 181_693_841_436
    static let manifestBytes = 181_752_181_866
    static let manifestFileCount = 42
}

/// Closed config/index/inventory validation for the pinned artifact. Reads only
/// bounded metadata, without constructing a model, native array or artifact
/// loader (the latter also verifies payloads). Not registered with placement.
struct GLM5NextArtifactMetadata {
    let inventory: GLM5NextWeightInventory
    let layout: GLM5NextStageLayout

    init(configuration: Data, index: Data,
         header: (String) throws -> GLM5NextHeaderInventory.Shard) throws {
        guard configuration.count == GLM5NextArtifactPin.configurationBytes,
              index.count == GLM5NextArtifactPin.indexBytes,
              sha256(configuration) == GLM5NextArtifactPin.configurationSHA256,
              sha256(index) == GLM5NextArtifactPin.indexSHA256 else {
            throw ProbeError("GLM config/index are not the pinned EigenLabs revision")
        }
        let config = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configuration)
        let c = config.textConfig
        let storage = try GLM5NextWeightInventory.packedStorage(declaredBy: config)
        guard storage == .nvfp4Hybrid, c.hiddenLayers == 45, c.numNextNPredictLayers == 1,
              c.hiddenSize == 4096, c.hcMult == 4, c.dtype == "bfloat16" else {
            throw ProbeError("Pinned GLM configuration has incompatible stage geometry or packing")
        }
        let inventory = try GLM5NextHeaderInventory.validate(
            configuration: config, index: index, storage: storage,
            configurationBytes: configuration.count, header: header)
        guard inventory.entries.count == GLM5NextArtifactPin.tensorCount,
              Set(inventory.entries.values.map { $0.tensor.shard }).count == GLM5NextArtifactPin.shardCount,
              Self.fingerprint(inventory) == GLM5NextArtifactPin.inventorySHA256 else {
            throw ProbeError("GLM headers are not the pinned EigenLabs inventory")
        }
        let layout = try GLM5NextStageLayout(inventory: inventory)
        guard layout.totalSource.bytes == GLM5NextArtifactPin.sourceBytes,
              layout.boundaryBytesPerToken == 32 * 1024 else {
            throw ProbeError("Pinned GLM source total or four-stream boundary differs")
        }
        self.inventory = inventory
        self.layout = layout
    }

    static func fingerprint(_ inventory: GLM5NextWeightInventory) -> String {
        ClusterPlacementInventory.fingerprint(inventory.entries.values.map {
            ClusterPlacementStoredTensor(name: $0.tensor.name, byteCount: $0.bytes,
                dtype: $0.tensor.dtype, shape: $0.tensor.shape)
        })
    }

    static func read(directory: URL) throws -> Self {
        guard directory.isFileURL else { throw ProbeError("GLM metadata requires a local directory") }
        func metadata(_ name: String, bytes: Int) throws -> Data {
            try withRegularFile(directory.appendingPathComponent(name)) { handle, size in
                guard size == bytes else { throw ProbeError("GLM metadata file size changed: \(name)") }
                return try readExactly(handle, count: bytes)
            }
        }
        let configuration = try metadata("config.json", bytes: GLM5NextArtifactPin.configurationBytes)
        let index = try metadata("model.safetensors.index.json", bytes: GLM5NextArtifactPin.indexBytes)
        return try .init(configuration: configuration, index: index) { name in
            try withRegularFile(directory.appendingPathComponent(name)) { handle, size in
                guard size >= 8 else { throw ProbeError("Truncated GLM shard: \(name)") }
                let prefix = try readExactly(handle, count: 8)
                let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                guard length > 0, length <= UInt64(GLM5NextHeaderInventory.limits.maximumHeaderBytes),
                      length <= UInt64(size - 8) else { throw ProbeError("Unbounded GLM header: \(name)") }
                return .init(data: try readExactly(handle, count: Int(length)), fileBytes: size)
            }
        }
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ProbeError("Truncated GLM metadata")
        }
        return data
    }

    private static func withRegularFile<T>(_ url: URL, body: (FileHandle, Int) throws -> T) throws -> T {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ProbeError("Cannot open GLM metadata: \(url.lastPathComponent)") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, let size = Int(exactly: before.st_size) else {
            throw ProbeError("GLM metadata must be a bounded regular file")
        }
        let result = try body(FileHandle(fileDescriptor: fd, closeOnDealloc: false), size)
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ProbeError("GLM metadata changed during inspection")
        }
        return result
    }
}

/// The bounded header/index join. The SDK owns tensor geometry and packing;
/// this layer owns file offsets and exact index coverage. Keeping the join
/// separate also permits tiny metadata fixtures without weakening artifact pins.
enum GLM5NextHeaderInventory {
    static let limits = GLM5NextArtifactLimits()
    struct Shard {
        let data: Data
        /// Full file size from stat; payload bytes are never read here.
        let fileBytes: Int
    }

    private struct Index: Decodable {
        struct Metadata: Decodable { let total_size: Int }
        let metadata: Metadata
        let weight_map: [String: String]
    }
    private struct Tensor: Decodable {
        let dtype: String
        let shape: [Int]
        let data_offsets: [Int]
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Header: Decodable {
        let tensors: [String: Tensor]
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var tensors: [String: Tensor] = [:]
            for key in container.allKeys {
                if key.stringValue == "__metadata__" {
                    _ = try container.decode([String: String].self, forKey: key)
                } else {
                    let fields = try container.nestedContainer(keyedBy: Key.self, forKey: key)
                    guard Set(fields.allKeys.map(\.stringValue)) == ["dtype", "shape", "data_offsets"] else {
                        throw ProbeError("Unexpected GLM tensor header fields")
                    }
                    tensors[key.stringValue] = try container.decode(Tensor.self, forKey: key)
                }
            }
            self.tensors = tensors
        }
    }

    static func validate(configuration: GLM5NextConfiguration, index: Data,
                         storage: GLM5NextWeightInventory.Storage, configurationBytes: Int = 0,
                         header: (String) throws -> Shard) throws -> GLM5NextWeightInventory {
        let c = configuration.textConfig
        guard (1...limits.maximumIndexBytes).contains(index.count),
              (0...limits.maximumConfigBytes).contains(configurationBytes),
              c.hiddenLayers <= 512, c.numNextNPredictLayers <= 1,
              c.nRoutedExperts <= 2048, configuration.visionConfig.depth <= 512 else {
            throw ProbeError("GLM metadata exceeds schema/input bounds")
        }
        let ceiling = (c.hiddenLayers + c.numNextNPredictLayers) * (c.nRoutedExperts * 9 + 100)
            + configuration.visionConfig.depth * 20 + 40
        guard ceiling <= limits.maximumTensors else { throw ProbeError("GLM expanded schema exceeds tensor bound") }
        // Header/index numbers are integers; reuse the duplicate-key scanner.
        let indexBytes = index.count
        try validateWorkerJSON(index)
        let index = try JSONDecoder().decode(Index.self, from: index)
        let shards = Set(index.weight_map.values)
        guard !index.weight_map.isEmpty, index.weight_map.count <= limits.maximumTensors,
              (1...limits.maximumShards).contains(shards.count), index.metadata.total_size > 0,
              shards.allSatisfy({ name in
                  (1...256).contains(name.utf8.count) && name.hasSuffix(".safetensors")
                      && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || [45, 46, 95].contains($0) }
              }) else { throw ProbeError("Invalid GLM index/shard coverage") }

        var tensors: [GLM5NextWeightInventory.Tensor] = []
        var spans: [String: Int] = [:]
        var metadataBytes = try sum(configurationBytes, indexBytes)
        // Include the decoded index and its strings in the same aggregate bound.
        metadataBytes = try sum(metadataBytes, index.weight_map.reduce(0) {
            $0 + $1.key.utf8.count * 4 + $1.value.utf8.count * 4 + 128
        })
        guard metadataBytes <= limits.maximumMetadataBytes else { throw ProbeError("GLM decoded index bound") }
        var payloadBytes = 0
        for shard in shards.sorted() {
            let source = try header(shard)
            guard (1...limits.maximumHeaderBytes).contains(source.data.count),
                  source.fileBytes >= 8, source.data.count <= source.fileBytes - 8 else {
                throw ProbeError("Invalid GLM shard header size")
            }
            metadataBytes = try sum(metadataBytes, source.data.count)
            guard metadataBytes <= limits.maximumMetadataBytes else { throw ProbeError("GLM aggregate metadata bound") }
            try validateWorkerJSON(source.data)
            let decoded = try JSONDecoder().decode(Header.self, from: source.data)
            guard decoded.tensors.values.allSatisfy({ $0.data_offsets.count == 2 }) else {
                throw ProbeError("Invalid GLM tensor offsets")
            }
            var cursor = 0
            for (name, tensor) in decoded.tensors.sorted(by: { $0.value.data_offsets[0] < $1.value.data_offsets[0] }) {
                let end = tensor.data_offsets[1]
                guard index.weight_map[name] == shard, spans[name] == nil,
                      tensors.count < limits.maximumTensors, tensor.data_offsets[0] == cursor,
                      end > cursor, end <= source.fileBytes - 8 - source.data.count,
                      end - cursor <= limits.maximumTensorBytes else {
                    throw ProbeError("GLM index/header/offset coverage differs: \(name)")
                }
                spans[name] = end - cursor
                tensors.append(.init(name: name, shape: tensor.shape, dtype: tensor.dtype, shard: shard))
                cursor = end
                metadataBytes = try sum(metadataBytes, 1024 + name.utf8.count * 4)
                guard metadataBytes <= limits.maximumMetadataBytes else { throw ProbeError("GLM decoded metadata bound") }
            }
            guard cursor == source.fileBytes - 8 - source.data.count else {
                throw ProbeError("GLM shard has trailing or unaccounted bytes")
            }
            payloadBytes = try sum(payloadBytes, cursor)
        }
        guard tensors.count == index.weight_map.count, payloadBytes == index.metadata.total_size else {
            throw ProbeError("GLM index tensor count or total_size differs")
        }
        let inventory = try GLM5NextWeightInventory.validate(configuration: configuration, tensors: tensors, storage: storage)
        guard inventory.entries.allSatisfy({ spans[$0.key] == $0.value.bytes }) else {
            throw ProbeError("GLM tensor offsets disagree with SDK-validated sizes")
        }
        return inventory
    }

    private static func sum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !result.overflow else { throw ProbeError("GLM metadata size overflow") }
        return result.partialValue
    }
}
