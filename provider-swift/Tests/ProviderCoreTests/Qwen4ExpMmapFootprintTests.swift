import Foundation
import Darwin
import Testing

@testable import ProviderCore

/// The resident-memory estimate for a qwen4_exp checkpoint must exclude the
/// n-gram PLE shards the loader leaves on disk (PLE SSD offload). Synthetic
/// accounting checks are independent of optional full-artifact checks and do
/// not establish physical 128-GiB hardware qualification.
@Suite("Qwen4 mmap footprint")
struct Qwen4ExpMmapFootprintTests {
    @Test func offloadWireFieldIsOptionalAndPreservesExactBytes() throws {
        let legacy = ModelInfo(id: "legacy", sizeBytes: 100, estimatedMemoryGb: 1)
        let encoded = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["ssd_offloaded_weight_bytes"] == nil)
        var offloaded = legacy
        offloaded.ssdOffloadedWeightBytes = 32_000_153_600
        let roundTrip = try JSONDecoder().decode(ModelInfo.self, from: JSONEncoder().encode(offloaded))
        #expect(roundTrip.ssdOffloadedWeightBytes == 32_000_153_600)
        #expect(roundTrip.estimatedMemoryGb == legacy.estimatedMemoryGb)
    }

    @Test func oversizedIndexIsRejectedBeforeReadingItsBody() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen4-index-bound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent(Qwen4ExpMmapFootprint.indexFileName)
        try Data().write(to: index)
        let handle = try FileHandle(forWritingTo: index)
        try handle.truncate(atOffset: UInt64(Qwen4ExpMmapFootprint.maximumIndexBytes + 1))
        try handle.close()
        #expect(Qwen4ExpMmapFootprint.excludedBytes(snapshotDir: root, modelType: "qwen4_exp", offloadEnabled: true) == 0)
    }

    @Test func nonRegularMetadataIsRejectedWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen4-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent(Qwen4ExpMmapFootprint.indexFileName)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(Qwen4ExpMmapFootprint.excludedBytes(snapshotDir: root, modelType: "qwen4_exp", offloadEnabled: true) == 0)
        try FileManager.default.removeItem(at: index)
        #expect(mkfifo(index.path, 0o600) == 0)
        #expect(Qwen4ExpMmapFootprint.excludedBytes(snapshotDir: root, modelType: "qwen4_exp", offloadEnabled: true) == 0)
        try FileManager.default.removeItem(at: index)
        let key = "model.language_model.layers.1.ple.ngram_embedding.shards.0.weight"
        try JSONSerialization.data(withJSONObject: ["weight_map": [key: "pipe.safetensors"]]).write(to: index)
        #expect(mkfifo(root.appendingPathComponent("pipe.safetensors").path, 0o600) == 0)
        #expect(Qwen4ExpMmapFootprint.excludedBytes(snapshotDir: root, modelType: "qwen4_exp", offloadEnabled: true) == 0)
    }

    @Test("Malformed PLE offsets cannot reduce memory admission")
    func malformedOffsetsFailClosed() throws {
        for offsets: [Any] in [[0, 65], [-1, 16], [0, 1.5], [false, 16], [32, 16]] {
            #expect(try syntheticFootprint(offsets: [offsets]) == 0)
        }
        #expect(try syntheticFootprint(offsets: [[0, 32], [16, 48]]) == 0)
        #expect(try syntheticFootprint(offsets: [[0, 32], [32, 64]]) == 64)
        #expect(try syntheticFootprint(offsets: [[0, 32], [32, 64]], symlinkWeights: true) == 64)
        #expect(try syntheticFootprint(offsets: [[0, 16]], shard: "../weights.safetensors") == 0)
        #expect(try syntheticFootprint(offsets: [[0, 16]]) == 0, "shape and byte range must agree")
        #expect(try syntheticFootprint(offsets: [[0, 32]], compute: [
            "dtype": "F32", "shape": [4, 2], "data_offsets": [16, 48]
        ]) == 0, "overlap with compute weights must not reduce admission")
        #expect(try syntheticFootprint(offsets: [[0, 32]], compute: [
            "dtype": "F32", "shape": [4, 2], "data_offsets": [32, 64]
        ]) == 32)
    }

    private func syntheticFootprint(
        offsets: [[Any]], shard: String = "weights.safetensors", compute: [String: Any]? = nil,
        symlinkWeights: Bool = false
    ) throws -> UInt64 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen4-footprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var tensors: [String: Any] = [:]
        var weightMap: [String: String] = [:]
        if let compute { tensors["model.layers.0.compute.weight"] = compute }
        for (index, value) in offsets.enumerated() {
            let key = "model.language_model.layers.1.ple.ngram_embedding.shards.\(index).weight"
            tensors[key] = ["dtype": "U32", "shape": [4, 2], "data_offsets": value]
            weightMap[key] = shard
        }
        let header = try JSONSerialization.data(withJSONObject: tensors)
        var length = UInt64(header.count).littleEndian
        var file = withUnsafeBytes(of: &length) { Data($0) }
        file.append(header)
        file.append(Data(repeating: 0, count: 64))
        let weightURL = root.appendingPathComponent("weights.safetensors")
        if symlinkWeights {
            let blob = root.appendingPathComponent("blob")
            try file.write(to: blob)
            try FileManager.default.createSymbolicLink(at: weightURL, withDestinationURL: blob)
        } else { try file.write(to: weightURL) }
        try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
            .write(to: root.appendingPathComponent("model.safetensors.index.json"))
        return Qwen4ExpMmapFootprint.excludedBytes(
            snapshotDir: root, modelType: "qwen4_exp", offloadEnabled: true)
    }

    static let flashNext = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["DARKBLOOM_QWEN4_MODEL_PATH"]
            ?? "/nonexistent/qwen38-native-test-fixture")

    @Test func nonQwen4OrOffloadOffExcludesNothing() {
        let dir = Self.flashNext
        #expect(
            Qwen4ExpMmapFootprint.excludedBytes(
                snapshotDir: dir, modelType: "qwen3_5", offloadEnabled: true) == 0)
        #expect(
            Qwen4ExpMmapFootprint.excludedBytes(
                snapshotDir: dir, modelType: "qwen4_exp", offloadEnabled: false) == 0)
        #expect(
            Qwen4ExpMmapFootprint.excludedBytes(
                snapshotDir: URL(fileURLWithPath: "/nonexistent"), modelType: "qwen4_exp",
                offloadEnabled: true) == 0)
    }

    @Test(
        "Flash-Next estimate excludes the mmap'd PLE shards",
        .enabled(
            if: FileManager.default.fileExists(
                atPath: flashNext.appendingPathComponent("model.safetensors.index.json").path),
            "Set DARKBLOOM_QWEN4_MODEL_PATH to an owned Flash-Next checkpoint"))
    func flashNextEstimateExcludesShards() throws {
        let excluded = Qwen4ExpMmapFootprint.excludedBytes(
            snapshotDir: Self.flashNext, modelType: "qwen4_exp", offloadEnabled: true)
        let gib = Double(excluded) / 1_073_741_824
        #expect(gib > 29 && gib < 31, "excluded \(gib) GiB")

        let info = try #require(
            ModelScanner.parseModelInfo(
                snapshotDir: Self.flashNext, modelName: "Qwen/Qwen3.8-Flash-Next"))
        let onDiskGb = Double(info.sizeBytes) / 1_073_741_824
        #expect(info.ssdOffloadedWeightBytes == excluded)
        print("qwen4 footprint: disk_bytes=\(info.sizeBytes) mapped_ple_bytes=\(excluded) load_estimate_gib=\(info.estimatedMemoryGb) native_transient_bytes=\(info.nativeLoadTransientBytes ?? 0)")
        #expect(info.sizeBytes > excluded)
        let native = try #require(Qwen4ExpLoadFootprint.estimate(
            snapshotDir: Self.flashNext, modelType: "qwen4_exp", sizeBytes: info.sizeBytes,
            offloadedBytes: excluded, offloadEnabled: true))
        let expected = Double(native.totalBytes) / 1_073_741_824
        #expect(info.nativeLoadTransientBytes == native.transientBytes)
        #expect(abs(info.estimatedMemoryGb - expected) < 0.000_001)
        #expect(
            info.estimatedMemoryGb > 74 && info.estimatedMemoryGb < 78,
            "estimate \(info.estimatedMemoryGb) GB")
        #expect(info.estimatedMemoryGb < Double(info.sizeBytes - excluded) / 1_073_741_824 * 1.2)
        // Arithmetic eligibility, not a physical 128-GiB qualification. Keep
        // the existing OS reserve, activation/KV headroom and outstanding C-M.
        let physical: UInt64 = 128 << 30
        let reserve = UnifiedMemoryCap.loadReserveBytes(physicalBytes: physical, configReserveBytes: 0, capFraction: 0.9)
        let headroom = ModelLoadAdmission.defaultLoadHeadroomGb
        #expect(ModelLoadAdmission.canLoad(weightsGb: info.estimatedMemoryGb, headroomGb: headroom,
            totalBytes: physical, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: reserve))
        #expect(!ModelLoadAdmission.canLoad(weightsGb: onDiskGb * 1.2, headroomGb: headroom,
            totalBytes: physical, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: reserve))
        #expect(!ModelLoadAdmission.canLoad(weightsGb: info.estimatedMemoryGb, headroomGb: headroom,
            totalBytes: physical, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: reserve,
            outstandingReservationBytes: 50 << 30))
        #expect(!ModelLoadAdmission.canLoad(weightsGb: info.estimatedMemoryGb, headroomGb: headroom,
            totalBytes: physical, systemAvailableBytes: 64 << 30, gpuActiveBytes: 0,
            gpuCacheBytes: 0, reserveBytes: reserve))
    }
}
