import CryptoKit
import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Opt-in byte accounting through the production writer. No model weights,
/// attention kernels or token generation are used. Synthetic zero values are
/// intentional: DBK3 encryption keeps serialized length independent of them.
@Suite("Complete checkpoint storage geometry", .serialized)
struct SSDCheckpointStorageGeometryTests {
    @Test("production-shaped CPU fixtures measure retained, written and read bytes",
          .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_RUN_STORAGE_GEOMETRY"] == "1",
                   "Opt-in CPU storage benchmark; writes several GiB of isolated encrypted files"))
    func productionGeometry() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let env = ProcessInfo.processInfo.environment
            let requestedPositions = env["DARKBLOOM_STORAGE_POSITIONS"] ?? "1024,16384,32768"
            let positions = try requestedPositions.split(separator: ",").map {
                guard let value = Int($0), value >= 1024, value % 1024 == 0 else { throw ProbeError.invalidPositions }
                return value
            }
            guard positions.count == 3, positions == positions.sorted(), Set(positions).count == 3 else {
                throw ProbeError.invalidPositions
            }
            var reports: [Report] = []
            for modelID in ["gemma-4-26b-qat-4bit", "gpt-oss-20b"] {
                let fixture = try GeometryFixture(modelID: modelID, positions: positions)
                defer { fixture.remove() }
                let baseline = try await fixture.measure(shared: false)
                let shared = try await fixture.measure(shared: true)
                #expect(shared.retainedBytes < baseline.retainedBytes)
                #expect(shared.bytesWritten == shared.retainedBytes)
                #expect(baseline.bytesWritten == baseline.retainedBytes)
                #expect(shared.donationReadBytes > baseline.donationReadBytes)
                reports.append(Report(modelID: modelID, configSHA256: fixture.configHash,
                    dtypeScenario: fixture.dtypeScenario, positions: positions,
                    baseline: baseline, shared: shared))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(reports)
            print("STORAGE_GEOMETRY_REPORT\n" + String(decoding: data, as: UTF8.self))
            if let output = env["DARKBLOOM_STORAGE_GEOMETRY_OUTPUT"] {
                guard output.hasPrefix("/") else { throw ProbeError.invalidOutput }
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }
}

private enum ProbeError: Error { case invalidPositions, invalidOutput, invalidConfig, incompleteWrite }

private struct Report: Codable {
    let modelID: String
    let configSHA256: String
    let dtypeScenario: String
    let positions: [Int]
    let baseline: Measurement
    let shared: Measurement
}

private struct Measurement: Codable {
    let retainedBytes: Int
    let bytesWritten: Int
    let donationReadBytes: Int
    let deepestRestoreReadBytes: Int
    let endpointLogicalBytes: [Int]
    let endpointTensorBytes: [Int]
}

private final class GeometryFixture {
    let modelID: String
    let positions: [Int]
    let configHash: String
    let dtypeScenario: String
    let layout: CBv2HistoricalAttentionLayout
    let tokens: [Int]
    let root: URL
    let key = SymmetricKey(size: .bits256)
    let identity: CBv2CompleteCheckpointIdentity

    init(modelID: String, positions: [Int]) throws {
        self.modelID = modelID
        self.positions = positions
        tokens = (0..<(positions.last! + 1)).map { $0 % 31 }
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(modelID)/snapshots/local/config.json")
        let data = try Data(contentsOf: config)
        configHash = Data(SHA256.hash(data: data)).hexString
        let kinds: [CBv2LayerKind]
        let dtype: DType
        if modelID == "gemma-4-26b-qat-4bit" {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = object["text_config"] else { throw ProbeError.invalidConfig }
            let configuration = try JSONDecoder().decode(Gemma4TextConfiguration.self,
                from: JSONSerialization.data(withJSONObject: text))
            kinds = configuration.cbv2LayerKinds
            dtype = .bfloat16
            dtypeScenario = "BF16 throughout, matching cached Gemma config; synthetic values"
        } else {
            let configuration = try JSONDecoder().decode(GPTOSSConfiguration.self, from: data)
            kinds = configuration.cbv2LayerKinds
            dtype = .float32
            dtypeScenario = "uniform FP32 storage scenario; not a fresh runtime dtype measurement"
        }
        layout = try .init(layerKinds: kinds, dtypes: Array(repeating: dtype, count: kinds.count))
        identity = .init(modelAggregateHash: "synthetic-geometry-\(configHash)",
            promptContractID: "storage-geometry-v1", buildID: "storage-geometry-probe",
            numericsFingerprint: "cpu-\(dtype)")
        root = try SSDTestDirectory.parent().appendingPathComponent("storage-geometry-\(UUID().uuidString)")
    }

    func measure(shared: Bool) async throws -> Measurement {
        let dedicated = root.appendingPathComponent(shared ? "shared" : "independent")
        let modelRoot = dedicated.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: dedicated, modelRoot: modelRoot)
        let store = SSDHybridCheckpointStore(config: .init(modelId: modelID, identity: identity,
            backendLayout: CBv2CompleteCheckpointManifest.historicalAttentionLayout,
            root: modelRoot, dedicatedRoot: dedicated, epochStore: nil,
            maxReadBytes: 4 << 30, maxStageMillis: 120_000, minEffectiveTokens: 1024,
            ttlSeconds: 3600, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) },
            diskBudgetBytes: { 32 << 30 }, maintainWholeRoot: {}),
            kekKey: key, kvBudget: nil, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 32 << 30)
        store.scanOnDisk()
        var logicalBytes: [Int] = []
        var tensorBytes: [Int] = []
        for position in positions {
            let descriptors = try layout.tensorDescriptors(position: position)
            let manifest = CBv2CompleteCheckpointManifest(identity: identity, position: position, chunkSize: 1024,
                prefixTokens: Array(tokens.prefix(position)), cacheSalt: "geometry-scope", assistantCodecID: nil,
                tensors: descriptors, backendLayout: CBv2CompleteCheckpointManifest.historicalAttentionLayout,
                attentionLayers: layout.layers)
            guard !shared || SSDSharedCheckpointPages.eligible(modelID: modelID, manifest: manifest,
                requestID: .init(1), maximumPlaintextBytes: 4 << 30) else { throw ProbeError.incompleteWrite }
            let arrays = descriptors.map { zeros($0.shape, dtype: $0.dtype.mlxDType, stream: .cpu) }
            eval(arrays)
            let source = CBv2CompleteCheckpointExport(manifest: manifest, arrays: arrays)
            let saved = await withCheckedContinuation { continuation in
                store.donate(source, requestID: shared ? .init(1) : nil,
                    tokens: tokens, cacheSalt: "geometry-scope") { continuation.resume(returning: $0) }
            }
            guard saved == [position] else { throw ProbeError.incompleteWrite }
            let file = fileURL(store: store, position: position)
            let mainBytes = try #require(SSDCheckpointPageFiles.info(file)).bytes
            logicalBytes.append(SSDCheckpointPageFiles.logicalBytes(checkpoint: file, manifestBytes: mainBytes))
            tensorBytes.append(try manifest.validateStructure())
        }
        let deepest = positions.last!
        let file = fileURL(store: store, position: deepest)
        var readBytes = 0
        var header: SSDBlockMetadata?
        var encoded = Data()
        enum ManifestRead: Error { case complete }
        do {
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: 4 << 30, onBytesRead: { readBytes += $0 },
                validateMetadata: { header = $0 }, consumeChunk: { index, data in
                    guard index == 0 else { throw ProbeError.incompleteWrite }
                    encoded = data
                    throw ManifestRead.complete
                })
        } catch ManifestRead.complete { }
        if shared {
            let envelope = try SSDSharedCheckpointPages.Envelope.decode(encoded)
            let metadata = try #require(header)
            let tag = try #require(SSDPrefixCache.hexDecode(metadata.lookupTag))
            try SSDSharedCheckpointPages.read(envelope: envelope, encoded: encoded,
                checkpoint: file, tag: tag, key: key,
                maximumPlaintextBytes: 4 << 30, check: {}, countRead: { readBytes += $0 },
                consume: { _, _ in })
        } else {
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: 4 << 30, requireEOF: true,
                onBytesRead: { readBytes += $0 }, validateMetadata: { _ in }, consumeChunk: { _, _ in })
        }
        let stats = store.stats()
        await store.closeAndWait()
        return Measurement(retainedBytes: stats.bytesOnDisk, bytesWritten: stats.bytesWritten,
            donationReadBytes: stats.donationReadBytes, deepestRestoreReadBytes: readBytes,
            endpointLogicalBytes: logicalBytes, endpointTensorBytes: tensorBytes)
    }

    private func fileURL(store: SSDHybridCheckpointStore, position: Int) -> URL {
        let chain = store.hashes(tokens: tokens, scope: "geometry-scope")
        let tag = store.lookupKeys.checkpointTag(chainHash: chain[position / PrefixCachePolicy.blockSize - 1], cacheSalt: "geometry-scope")
        return SSDBlockStore.fileURL(root: store.config.root, tag16Hex: Data(tag.prefix(16)).hexString)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
