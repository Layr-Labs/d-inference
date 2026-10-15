import CryptoKit
import Darwin
import Foundation
import MLXLLM
import MLXVLM
import ProviderCoreFoundation

enum GLM5NextManagedLoadError: Error, Equatable {
    case invalidManifest
    case metadata(String)
    case changed(String)
    case admission, lifecycle
    case managedLoadRequired, identityMismatch, retirementUnproven
}

/// Catalog-pinned local files, not a locally asserted verification receipt.
/// Discovery/preflight only stats payloads; the existing WeightHasher is invoked
/// exclusively by the admitted on-demand load.
struct GLM5NextManifestSnapshot: Sendable {
    struct FileState: Equatable, Sendable {
        let device: UInt64, inode: UInt64, bytes: Int64
        let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
        init(_ value: stat) throws {
            guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else {
                throw GLM5NextManagedLoadError.metadata("regular file required")
            }
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = UInt64(value.st_ino)
            bytes = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    let directory: URL
    let catalog: CatalogModel
    let manifest: ModelManifest
    let files: [String: ManifestFile]
    private let states: [String: FileState]
    private let rootDevice: UInt64
    private let rootInode: UInt64

    init(directory: URL, catalog: CatalogModel, manifest: ModelManifest) throws {
        guard directory.isFileURL, catalog.version != nil, catalog.aggregateSHA256 != nil,
            catalog.r2Prefix != nil
        else { throw GLM5NextManagedLoadError.invalidManifest }
        try ModelCatalogClient.validateManifestBounds(manifest)
        try ModelDownloader.validateArtifactManifest(manifest, model: catalog)
        // File paths are part of the reviewed manifest identity. The native
        // artifact is flat; accepting nested/symlink aliases would change it.
        guard
            manifest.files.allSatisfy({
                !$0.path.contains("/") && $0.sizeBytes > 0
                    && $0.role == ModelScanner.roleFor(filename: $0.path)
                    && ($0.path.hasSuffix(".safetensors")
                        || $0.sizeBytes <= ($0.path == "tokenizer.json" ? 512 << 20 : 32 << 20))
            })
        else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        var aggregate = SHA256()
        for file in manifest.files.sorted(by: { $0.path < $1.path }) {
            let bytes = Array(file.sha256.utf8)
            var digest = Data()
            for i in stride(from: 0, to: bytes.count, by: 2) {
                guard
                    let byte = UInt8(
                        String(decoding: bytes[i ..< (i + 2)], as: UTF8.self), radix: 16)
                else {
                    throw GLM5NextManagedLoadError.invalidManifest
                }
                digest.append(byte)
            }
            aggregate.update(data: digest)
        }
        guard Self.hex(aggregate.finalize()) == manifest.aggregateSHA256 else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        let root = directory.standardizedFileURL
        var rootState = stat()
        guard lstat(root.path, &rootState) == 0, rootState.st_mode & S_IFMT == S_IFDIR else {
            throw GLM5NextManagedLoadError.metadata("regular snapshot directory required")
        }
        var states: [String: FileState] = [:]
        for file in manifest.files {
            let state = try Self.state(root.appendingPathComponent(file.path))
            guard state.bytes == file.sizeBytes else {
                throw GLM5NextManagedLoadError.changed(file.path)
            }
            states[file.path] = state
        }
        self.directory = root
        self.catalog = catalog
        self.manifest = manifest
        self.files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        self.states = states
        self.rootDevice = UInt64(bitPattern: Int64(rootState.st_dev))
        self.rootInode = UInt64(rootState.st_ino)
        try recheck()
    }

    func recheck() throws {
        try Task.checkCancellation()
        var root = stat()
        guard lstat(directory.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR,
            UInt64(bitPattern: Int64(root.st_dev)) == rootDevice, UInt64(root.st_ino) == rootInode
        else {
            throw GLM5NextManagedLoadError.changed("snapshot directory")
        }
        guard ModelDownloader.revisionIntegrityFilesMatch(at: directory, manifest: manifest) else {
            throw GLM5NextManagedLoadError.changed("integrity file inventory")
        }
        for (name, expected) in states {
            guard try Self.state(directory.appendingPathComponent(name)) == expected else {
                throw GLM5NextManagedLoadError.changed(name)
            }
        }
    }

    func readMetadata(_ name: String, maximumBytes: Int) throws -> Data {
        guard let expected = states[name], expected.bytes > 0, expected.bytes <= maximumBytes else {
            throw GLM5NextManagedLoadError.metadata(name)
        }
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GLM5NextManagedLoadError.changed(name) }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, try FileState(value) == expected else {
            throw GLM5NextManagedLoadError.changed(name)
        }
        var data = Data(count: Int(expected.bytes))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GLM5NextManagedLoadError.changed(name) }
                offset += count
            }
        }
        guard fstat(fd, &value) == 0, try FileState(value) == expected,
            try Self.state(url) == expected
        else {
            throw GLM5NextManagedLoadError.changed(name)
        }
        return data
    }

    /// Called only after actual pending-load admission and artifact writer ownership.
    func verifyContents() throws {
        try recheck()
        let actual = WeightHasher.hashFilesWithRelativeKey(
            manifest.files.map {
                (file: directory.appendingPathComponent($0.path), sortKey: $0.path)
            })
        try recheck()
        guard actual == manifest.aggregateSHA256 else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
    }

    /// The native reader verifies every core file against these exact expected
    /// hashes while parsing the closed inventory. Verify the complementary
    /// tokenizer/template files through the provider's existing hashing funnel,
    /// rather than perform a redundant second full-model payload read.
    func verifyAuxiliaryContents(nativeIdentity: GLM5NextArtifactIdentity) throws {
        try recheck()
        let expectedCore = Set(
            files.keys.filter {
                $0 == "config.json" || $0 == "model.safetensors.index.json"
                    || $0.hasSuffix(".safetensors")
            })
        guard Set(nativeIdentity.files.keys) == expectedCore,
            nativeIdentity.files.allSatisfy({ name, expected in
                files[name]?.sha256 == expected.sha256
                    && files[name]?.sizeBytes == Int64(expected.bytes)
            })
        else { throw GLM5NextManagedLoadError.identityMismatch }
        for file in manifest.files where !expectedCore.contains(file.path) {
            try Task.checkCancellation()
            guard
                let digest = WeightHasher.hashSingleFile(
                    at: directory.appendingPathComponent(file.path)),
                Self.hex(digest) == file.sha256
            else { throw GLM5NextManagedLoadError.identityMismatch }
        }
        try recheck()
    }

    private static func state(_ url: URL) throws -> FileState {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw GLM5NextManagedLoadError.changed(url.lastPathComponent)
        }
        return try FileState(value)
    }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// An explicit separately catalog-pinned tokenizer/processor snapshot. It uses
/// ModelConfiguration.tokenizerSource; it never rewrites the weight snapshot.
/// The caller must select this reviewed composition, not infer it from a failed
/// raw template or the presence of official reference fixtures.
struct GLM5NextTokenizerComposition: Sendable {
    let snapshot: GLM5NextManifestSnapshot
    let weightAggregateSHA256: String
    init(
        directory: URL, catalog: CatalogModel, manifest: ModelManifest,
        weightAggregateSHA256: String
    ) throws {
        guard
            manifest.files.allSatisfy({ !ModelScanner.isWeightFile($0.path) && $0.role != "weight" }
            ),
            weightAggregateSHA256.count == 64
        else { throw GLM5NextManagedLoadError.invalidManifest }
        snapshot = try .init(directory: directory, catalog: catalog, manifest: manifest)
        self.weightAggregateSHA256 = weightAggregateSHA256
    }
}

struct GLM5NextArtifactPlan: Sendable {
    let weights: GLM5NextManifestSnapshot
    let tokenizer: GLM5NextManifestSnapshot
    let configuration: GLM5NextConfiguration
    let descriptors: [GLM5NextWeightInventory.Tensor]
    let nativeIdentity: GLM5NextArtifactIdentity
    let processorConfiguration: GLM5NextProcessorConfiguration
    let quotation: GLM5NextLoadQuotation
    /// Expected identities from the pinned manifests. File bytes are verified
    /// only by the admitted on-demand load, never by metadata discovery.
    let rawTemplateSHA256: String
    let selectedTemplateSHA256: String
    let eosTokenIDs: Set<Int>
    var usesSeparateTokenizer: Bool { tokenizer.directory != weights.directory }
    var expectsOfficialReferenceTemplate: Bool {
        selectedTemplateSHA256 == GLM5NextPromptPolicy.templateSHA256
    }

    static func inspect(
        directory: URL, catalog: CatalogModel, manifest: ModelManifest,
        tokenizerComposition: GLM5NextTokenizerComposition? = nil
    ) throws -> Self {
        let weights = try GLM5NextManifestSnapshot(
            directory: directory, catalog: catalog, manifest: manifest)
        guard
            manifest.files.filter({ ModelScanner.isWeightFile($0.path) })
                .allSatisfy({ $0.path.hasSuffix(".safetensors") })
        else {
            throw GLM5NextManagedLoadError.metadata(
                "only indexed safetensors weights are supported")
        }
        guard let source = catalog.huggingFaceArtifact else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        // Validates the exact repository/revision syntax without any I/O.
        _ = try source.downloadURL(for: "config.json")
        let config = try JSONDecoder().decode(
            GLM5NextConfiguration.self,
            from: weights.readMetadata("config.json", maximumBytes: 2 << 20))
        guard config.textConfig.hiddenLayers <= 512, config.textConfig.numNextNPredictLayers == 1,
            config.textConfig.nRoutedExperts <= 2048, config.visionConfig.depth <= 512,
            (config.textConfig.hiddenLayers + 1) * (config.textConfig.nRoutedExperts * 9 + 100)
                + config.visionConfig.depth * 20 + 40 <= 200_000
        else {
            throw GLM5NextManagedLoadError.metadata("bounded GLM schema")
        }
        struct Index: Decodable {
            let weightMap: [String: String]
            let metadata: Metadata
            enum CodingKeys: String, CodingKey {
                case weightMap = "weight_map"
                case metadata
            }
            struct Metadata: Decodable {
                let totalSize: Int
                enum CodingKeys: String, CodingKey { case totalSize = "total_size" }
            }
        }
        let index = try JSONDecoder().decode(
            Index.self,
            from: weights.readMetadata("model.safetensors.index.json", maximumBytes: 32 << 20))
        let schema = try GLM5NextWeightInventory.expectedTensors(
            configuration: config,
            storage: .vontraQ4, shard: "placeholder.safetensors")
        guard Set(schema.map(\.name)) == Set(index.weightMap.keys) else {
            throw GLM5NextManagedLoadError.metadata("index tensor inventory")
        }
        let shards = Set(index.weightMap.values)
        guard !shards.isEmpty, shards.count <= 256,
            shards == Set(manifest.files.filter { $0.path.hasSuffix(".safetensors") }.map(\.path))
        else {
            throw GLM5NextManagedLoadError.metadata("index shard inventory")
        }
        let descriptors = try schema.map { entry -> GLM5NextWeightInventory.Tensor in
            guard let shard = index.weightMap[entry.name], weights.files[shard] != nil,
                shard.hasSuffix(".safetensors")
            else { throw GLM5NextManagedLoadError.invalidManifest }
            return .init(name: entry.name, shape: entry.shape, dtype: entry.dtype, shard: shard)
        }
        let inventory = try GLM5NextWeightInventory.validate(
            configuration: config, tensors: descriptors, storage: .vontraQ4)
        guard inventory.entries.values.reduce(0, { $0 + $1.bytes }) == index.metadata.totalSize
        else {
            throw GLM5NextManagedLoadError.metadata("index total_size")
        }
        var tokenizer = weights
        if let composition = tokenizerComposition {
            guard composition.weightAggregateSHA256 == manifest.aggregateSHA256,
                composition.snapshot.directory != weights.directory
            else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
            tokenizer = composition.snapshot
            // A reviewed template composition must not silently remap the
            // original embedding vocabulary. Only the template value may differ
            // in tokenizer_config; all lexical artifacts remain byte-identical.
            for name in [
                "tokenizer.json", "tokenizer.model", "vocab.json", "merges.txt",
                "added_tokens.json", "special_tokens_map.json",
            ] {
                guard weights.files[name]?.sha256 == tokenizer.files[name]?.sha256,
                    weights.files[name]?.sizeBytes == tokenizer.files[name]?.sizeBytes
                else {
                    throw GLM5NextManagedLoadError.metadata(
                        "composition changes tokenizer vocabulary")
                }
            }
            func tokenizerOptions(_ snapshot: GLM5NextManifestSnapshot) throws -> Data {
                guard
                    var object = try JSONSerialization.jsonObject(
                        with:
                            snapshot.readMetadata("tokenizer_config.json", maximumBytes: 4 << 20))
                        as? [String: Any]
                else {
                    throw GLM5NextManagedLoadError.metadata("tokenizer configuration")
                }
                object.removeValue(forKey: "chat_template")
                return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            }
            guard try tokenizerOptions(weights) == tokenizerOptions(tokenizer) else {
                throw GLM5NextManagedLoadError.metadata(
                    "composition changes non-template tokenizer options")
            }
        }
        guard tokenizer.files["tokenizer.json"] != nil,
            tokenizer.files["tokenizer_config.json"] != nil,
            tokenizer.files["tokenizer.json"]!.sizeBytes <= 512 << 20
        else {
            throw GLM5NextManagedLoadError.metadata("bounded local tokenizer required")
        }
        _ = try tokenizer.readMetadata("tokenizer_config.json", maximumBytes: 4 << 20)
        _ = try tokenizer.readMetadata("chat_template.jinja", maximumBytes: 2 << 20)
        let processor = try processorConfiguration(
            tokenizer.readMetadata("processor_config.json", maximumBytes: 1 << 20),
            configuration: config)
        let coreFiles = Set(["config.json", "model.safetensors.index.json"]).union(shards)
        let identityFiles = Dictionary(
            uniqueKeysWithValues: try coreFiles.map { name in
                guard let file = weights.files[name], let bytes = Int(exactly: file.sizeBytes)
                else {
                    throw GLM5NextManagedLoadError.invalidManifest
                }
                return (name, GLM5NextArtifactIdentity.File(bytes: bytes, sha256: file.sha256))
            })
        guard let rawTemplate = weights.files["chat_template.jinja"]?.sha256,
            let selectedTemplate = tokenizer.files["chat_template.jinja"]?.sha256
        else {
            throw GLM5NextManagedLoadError.metadata("template identity")
        }
        let quotation = try GLM5NextLoadQuotation(
            manifest: manifest, inventory: inventory,
            tokenizerManifest: tokenizer.manifest)
        var eos = Set(config.textConfig.eosTokenIds?.values ?? [])
        if weights.files["generation_config.json"] != nil {
            struct Generation: Decodable {
                let eosTokenID: GLM5NextTokenIDs?
                enum CodingKeys: String, CodingKey { case eosTokenID = "eos_token_id" }
            }
            let generation = try JSONDecoder().decode(
                Generation.self,
                from: weights.readMetadata("generation_config.json", maximumBytes: 1 << 20))
            eos.formUnion(generation.eosTokenID?.values ?? [])
        }
        guard eos.allSatisfy({ (0 ..< config.textConfig.vocabularySize).contains($0) }) else {
            throw GLM5NextManagedLoadError.metadata("generation EOS vocabulary")
        }
        try weights.recheck()
        try tokenizer.recheck()
        return .init(
            weights: weights, tokenizer: tokenizer, configuration: config,
            descriptors: descriptors,
            nativeIdentity: .init(
                repository: source.repoID,
                revision: source.revision, files: identityFiles), processorConfiguration: processor,
            quotation: quotation, rawTemplateSHA256: rawTemplate,
            selectedTemplateSHA256: selectedTemplate,
            eosTokenIDs: eos)
    }

    private static func processorConfiguration(_ data: Data, configuration: GLM5NextConfiguration)
        throws
        -> GLM5NextProcessorConfiguration
    {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(raw.keys) == ["processor_class", "image_processor", "video_processor"]
        else {
            throw GLM5NextManagedLoadError.metadata("processor fields")
        }
        let allowed: Set<String> = [
            "do_rescale", "patch_expand_factor", "merge_size", "image_mean", "image_std",
            "temporal_patch_size", "patch_size", "min_image_tokens", "max_image_tokens", "fps",
            "image_processor_type", "video_processor_type",
        ]
        for (name, typeKey, expectedType) in [
            ("image_processor", "image_processor_type", "Glm5NextImageProcessor"),
            ("video_processor", "video_processor_type", "Glm5NextVideoProcessor"),
        ] {
            guard let fields = raw[name] as? [String: Any], Set(fields.keys).isSubset(of: allowed),
                fields[typeKey] as? String == expectedType
            else {
                throw GLM5NextManagedLoadError.metadata("unsupported processor mode")
            }
        }
        struct Processor: Decodable {
            struct Media: Decodable {
                let doRescale: Bool, patchExpandFactor: Int, mergeSize: Int
                let imageMean: [Float], imageStd: [Float]
                let temporalPatchSize: Int, patchSize: Int, minImageTokens: Int,
                    maxImageTokens: Int
                let fps: Double?
                enum CodingKeys: String, CodingKey {
                    case doRescale = "do_rescale"
                    case patchExpandFactor = "patch_expand_factor"
                    case mergeSize = "merge_size"
                    case imageMean = "image_mean"
                    case imageStd = "image_std"
                    case temporalPatchSize = "temporal_patch_size"
                    case patchSize = "patch_size"
                    case minImageTokens = "min_image_tokens"
                    case maxImageTokens = "max_image_tokens"
                    case fps
                }
            }
            let processorClass: String
            let imageProcessor: Media
            let videoProcessor: Media
            enum CodingKeys: String, CodingKey {
                case processorClass = "processor_class"
                case imageProcessor = "image_processor"
                case videoProcessor = "video_processor"
            }
        }
        let p = try JSONDecoder().decode(Processor.self, from: data)
        guard p.processorClass == "Glm5NextProcessor", p.videoProcessor.fps == 2 else {
            throw GLM5NextManagedLoadError.metadata("processor class/sampling")
        }
        for m in [p.imageProcessor, p.videoProcessor] {
            guard m.doRescale, m.patchExpandFactor == 1,
                m.mergeSize == configuration.visionConfig.spatialMergeSize,
                m.temporalPatchSize == configuration.visionConfig.temporalPatchSize,
                m.patchSize == configuration.visionConfig.patchSize,
                m.imageMean == GLM5NextProcessor.mean,
                m.imageStd == GLM5NextProcessor.standardDeviation
            else {
                throw GLM5NextManagedLoadError.metadata("processor pixel contract")
            }
        }
        return try .init(
            patchSize: p.imageProcessor.patchSize,
            imageMinimumTokens: p.imageProcessor.minImageTokens,
            imageMaximumTokens: p.imageProcessor.maxImageTokens,
            videoMinimumTokens: p.videoProcessor.minImageTokens,
            videoMaximumTokens: p.videoProcessor.maxImageTokens)
    }
}
