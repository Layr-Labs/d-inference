import Foundation
import Darwin
import MLXLLM

/// Load-time backing for the native, incrementally materialized Qwen4 loader.
/// This is not a KV/activation reserve or a measured-residency substitution.
/// Unknown layouts retain the scanner's ordinary 1.2 estimate.
enum Qwen4ExpLoadFootprint {
    struct Estimate: Equatable {
        let residentBytes: UInt64
        let transientBytes: UInt64
        var totalBytes: UInt64 { residentBytes + transientBytes }
    }

    /// Retain one whole shard of staging headroom, or the larger of the actual
    /// native-copy envelopes, plus 1 GiB for loader metadata and small objects.
    /// The native loader reads directly into final backing, materializes one
    /// SwitchGLU at a time after dropping staging aliases, and clears its pool.
    /// We additionally price a complete vision tower and embedded assistant
    /// copy, even though only their transformed tensors need duplicate backing.
    /// FP16 is deliberately ineligible: its configurable conversion chunk can
    /// change this bound. All weights, including MTP and vision, remain counted.
    static func estimate(
        snapshotDir: URL, modelType: String?, sizeBytes: UInt64,
        offloadedBytes: UInt64,
        offloadEnabled: Bool = Qwen4ExpPLEResidency.useMmap
    ) -> Estimate? {
        guard getpagesize() == 16_384, offloadEnabled, let modelType,
            Qwen4ExpPLEResidency.qwen4ExpModelTypes.contains(
                modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            offloadedBytes > 0, offloadedBytes < sizeBytes,
            let configData = Qwen4ExpMmapFootprint.boundedIndex(
                snapshotDir.appendingPathComponent("config.json")),
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
            let currentModelType = config["model_type"] as? String,
            currentModelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            let data = Qwen4ExpMmapFootprint.boundedIndex(
                snapshotDir.appendingPathComponent(Qwen4ExpMmapFootprint.indexFileName)),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = root["weight_map"] as? [String: String],
            !weightMap.isEmpty, weightMap.count <= 20_000
        else { return nil }

        let shards = Set(weightMap.values)
        guard !shards.isEmpty, shards.count <= 64,
            shards.allSatisfy({ !$0.isEmpty && $0 == ($0 as NSString).lastPathComponent
                && $0.hasSuffix(".safetensors") }) else { return nil }
        // loadWeights enumerates recursively, including hidden files. A second
        // unindexed/nested payload must not evade this smaller load allowance.
        guard let enumerator = FileManager.default.enumerator(
            at: snapshotDir, includingPropertiesForKeys: nil) else { return nil }
        var discovered: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            guard url.deletingLastPathComponent().standardizedFileURL
                == snapshotDir.standardizedFileURL else { return nil }
            discovered.insert(url.lastPathComponent)
        }
        guard discovered == shards else { return nil }

        var fileBytes: UInt64 = 0
        var headerBytes: UInt64 = 0
        var excludedBytes: UInt64 = 0
        var largestShard: UInt64 = 0
        var visionBytes: UInt64 = 0
        var assistantBytes: UInt64 = 0
        var fusionGroups: [String: UInt64] = [:]
        var names: Set<String> = []
        for shard in shards.sorted() {
            guard let header = Qwen4ExpMmapFootprint.readHeader(
                snapshotDir.appendingPathComponent(shard)),
                add(header.fileBytes, to: &fileBytes),
                add(header.headerBytes, to: &headerBytes), headerBytes <= 16 << 20
            else { return nil }
            largestShard = max(largestShard, header.fileBytes)
            for (key, raw) in header.tensors where key != "__metadata__" {
                guard names.insert(key).inserted, weightMap[key] == shard,
                    let tensor = raw as? [String: Any],
                    let dtype = tensor["dtype"] as? String,
                    let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2,
                    let start = UInt64(offsets[0].stringValue),
                    let end = UInt64(offsets[1].stringValue), end >= start
                else { return nil }
                let bytes = end - start
                let excluded = Qwen4ExpWeightSanitizer.shouldDrop(key, mmapPLE: true)
                    && !Qwen4ExpWeightSanitizer.shouldDrop(key, mmapPLE: false)
                if excluded {
                    guard add(bytes, to: &excludedBytes) else { return nil }
                    continue
                }
                guard ["BF16", "F32", "U32", "I32", "I64"].contains(dtype) else { return nil }
                if key.hasPrefix("mtp.") || key.contains(".mtp.") {
                    guard add(bytes, to: &assistantBytes) else { return nil }
                } else if key.hasPrefix("vision_tower") || key.hasPrefix("model.visual")
                    || key.contains(".visual.") {
                    guard add(bytes, to: &visionBytes) else { return nil }
                } else if let prefix = fusionPrefix(key) {
                    var current = fusionGroups[prefix, default: 0]
                    guard add(bytes, to: &current) else { return nil }
                    fusionGroups[prefix] = current
                }
            }
        }
        guard names == Set(weightMap.keys), fileBytes == sizeBytes,
            excludedBytes == offloadedBytes else { return nil }
        // At most two complete sets of page-rounded tensor allocations, in
        // addition to payload bytes. 16 KiB is the supported Apple Silicon page.
        var copies = UInt64(names.count) * 2 * 16_384
        for bytes in [fusionGroups.values.max() ?? 0, visionBytes, assistantBytes] {
            guard add(bytes, to: &copies) else { return nil }
        }
        var transient = max(largestShard, copies)
        guard add(1 << 30, to: &transient) else { return nil }
        let resident = sizeBytes - offloadedBytes
        guard resident <= UInt64.max - transient else { return nil }
        return Estimate(residentBytes: resident, transientBytes: transient)
    }

    /// Hashing/hooks may suspend between scan/admission and actual allocation.
    /// An obsolete smaller native allowance must fail closed before loading.
    static func isCurrent(_ info: ModelInfo, directory: URL) -> Bool {
        guard let declared = info.nativeLoadTransientBytes else { return true }
        guard let excluded = info.ssdOffloadedWeightBytes,
            let current = estimate(snapshotDir: directory, modelType: info.modelType,
                sizeBytes: info.sizeBytes, offloadedBytes: excluded),
            declared >= current.transientBytes,
            info.estimatedMemoryGb >= Double(current.totalBytes) / 1_073_741_824
        else { return false }
        return true
    }

    private static func fusionPrefix(_ key: String) -> String? {
        for marker in [".switch_mlp.gate_proj.", ".switch_mlp.up_proj."] {
            if let range = key.range(of: marker) { return String(key[..<range.lowerBound]) }
        }
        return nil
    }

    private static func add(_ value: UInt64, to total: inout UInt64) -> Bool {
        let (next, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { return false }
        total = next
        return true
    }
}
