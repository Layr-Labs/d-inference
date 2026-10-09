import CryptoKit
import Foundation
import MLX

/// Hashes each given stored tensor through its verified descriptor, one block
/// at a time. Nothing is materialized: no tensor reaches MLX or the GPU.
func layerStageTensorContentInventory(_ descriptors: [String: TensorDescriptor],
                                      check: () throws -> Void) throws -> LayerStageTensorContentInventory {
    var block = Data(count: CheckpointAlignedReadPlan.maximumScratchRequestBytes)
    let records = try descriptors.map { name, tensor -> LayerStageTensorContentRecord in
        let dtype: String
        switch tensor.dtype {
        case .uint32: dtype = "U32"
        case .float32: dtype = "F32"
        case .float16: dtype = "F16"
        case .bfloat16: dtype = "BF16"
        default: throw ProbeError("Unsupported checkpoint tensor dtype for a content inventory: \(name)")
        }
        let layout = try LayerStageTensorLayout(canonicalName: name, shape: tensor.shape, sourceDType: dtype,
                                                byteCount: tensor.byteCount)
        let source = try LayerStageSourceTensor(layout: layout, sourceFile: tensor.file.path, sourceOffset: tensor.offset)
        var hash = SHA256(), done = 0
        while done < tensor.byteCount {
            try check()
            let count = min(block.count, tensor.byteCount - done)
            try block.withUnsafeMutableBytes { bytes in
                let part = UnsafeMutableRawBufferPointer(rebasing: bytes[..<count])
                try tensor.file.read(into: part, offset: tensor.offset + done)
                hash.update(bufferPointer: UnsafeRawBufferPointer(part))
            }
            done += count
        }
        return try .init(source: source, contentSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    return try .init(records: records.sorted {
        let (a, b) = ($0.source, $1.source)
        return a.sourceFile == b.sourceFile ? a.sourceOffset < b.sourceOffset
            : a.sourceFile.utf8.lexicographicallyPrecedes(b.sourceFile.utf8)
    })
}

/// Computes the content inventory of a registered artifact on this Mac: every
/// file is verified against the pinned manifest and aggregate, the stored
/// tensors must be exactly the registered layout inventory, and each one's
/// stored bytes are hashed. No model is constructed and no collective created.
/// The result is what a specification pins, or what its pin is checked against.
public enum QwenContentInventoryGenerator {
    public struct Receipt: Encodable, Sendable {
        public let schema = "qwen_registered_content_inventory_v1"
        public let model: String
        public let verifiedAggregateSHA256: String
        public let contentInventorySHA256: String
        /// The specification's pin, absent for a model nobody has inventoried.
        public let registeredContentInventorySHA256: String?
        public let matchesRegisteredPin: Bool?
        /// Equal to the specification's pinned `inventorySHA256`; checked.
        public let layoutInventorySHA256: String
        /// What a local load derives and commits to for the same artifact.
        public let sourceTensorManifestSHA256: String
        public let tensorCount: Int
        public let payloadBytes: Int
        public let encodedBytes: Int
        public let verifySeconds: Double
        public let hashSeconds: Double
        public let modelConstructed = false
        public let collectiveCreated = false
    }

    public struct Output: Sendable {
        /// The canonical document.
        public let document: Data
        /// The generated Swift source that embeds it in the runtime.
        public let swiftSource: String
        public let receipt: Receipt
    }

    public static func run(modelDirectory: URL, deadlineUptimeNanoseconds: UInt64) throws -> Output {
        func check() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
                throw ProbeError("Content inventory passed its local deadline")
            }
        }
        let configuration = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                       maximumBytes: 1_048_576)
        let manifest = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                  maximumBytes: 4_194_304)
        // The artifact's own configuration selects the registered model.
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: {
            $0.configurationSHA256 == sha256(configuration)
        }) else { throw ProbeError("Configuration is not a registered model's") }
        let started = DispatchTime.now().uptimeNanoseconds
        let checkpoint = try VerifiedCheckpoint(directory: modelDirectory, configurationData: configuration,
            expectedAggregateSHA256: specification.artifactSHA256, maximumPayloadBytes: specification.manifestBytes,
            expectedManifestSHA256: specification.manifestSHA256)
        try check()
        let verified = DispatchTime.now().uptimeNanoseconds
        // Stored names are canonical in a converted artifact. The plan refuses
        // an unknown name and returns nil for the vision and MTP tensors no
        // stage owns; admission then requires the exact registered layout.
        let plan = try QwenLayerStagePlan(configuration: configuration,
            ranges: [0..<(specification.layers / 2), (specification.layers / 2)..<specification.layers])
        let retained = try tensorDescriptors(checkpoint: checkpoint).filter {
            try plan.parameter(canonicalSourceName: $0.key) != nil
        }
        // Hash through uncached aligned reads, as a stage load reads its tensors:
        // file cache left behind here is memory a later load gate does not count as free.
        try checkpoint.bypassTensorPayloadCache()
        let inventory = try layerStageTensorContentInventory(retained, check: check)
        try checkpoint.checkUnchanged()
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: configuration, manifest: manifest,
            expectedArtifactAggregateSHA256: checkpoint.aggregate,
            canonicalTensors: inventory.records.map {
                let layout = $0.source.layout
                return .init(name: layout.canonicalName, shape: layout.shape, sourceDType: layout.sourceDType,
                             byteCount: layout.byteCount)
            })
        guard inventory.layoutInventorySHA256 == profile.canonicalInventorySHA256 else {
            throw ProbeError("Content inventory differs from the registered layout inventory")
        }
        let document = inventory.encoded(), digest = sha256(document)
        let finished = DispatchTime.now().uptimeNanoseconds
        return Output(document: document,
            swiftSource: try QwenRegisteredContentInventory.swiftSource(model: specification.model, document: document),
            receipt: Receipt(model: specification.model.rawValue, verifiedAggregateSHA256: checkpoint.aggregate,
                contentInventorySHA256: digest,
                registeredContentInventorySHA256: specification.contentInventorySHA256,
                matchesRegisteredPin: specification.contentInventorySHA256.map { $0 == digest },
                layoutInventorySHA256: inventory.layoutInventorySHA256,
                sourceTensorManifestSHA256: try QwenStageSourceTensorManifest.fingerprint(inventory,
                    bf16ConversionEnabled: profile.requiredBF16ConversionPolicy),
                tensorCount: inventory.records.count, payloadBytes: inventory.payloadBytes,
                encodedBytes: document.count, verifySeconds: Double(verified - started) / 1e9,
                hashSeconds: Double(finished - verified) / 1e9))
    }
}
