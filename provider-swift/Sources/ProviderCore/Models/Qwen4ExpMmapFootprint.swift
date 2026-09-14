import Foundation
import CoreFoundation
import Darwin
import MLXLLM

/// Bytes of a qwen4_exp checkpoint excluded from the MLX weight allocation.
/// Mapped file pages can still occupy the OS page cache.
///
/// With PLE SSD offload on (the default), the Qwen4 loader drops the n-gram
/// embedding shards from the in-memory load (`Qwen4ExpWeightSanitizer`) and
/// the PLE layer reads rows through file mappings instead. Admission excludes
/// only structurally validated payload bytes from the existing padded estimate;
/// it does not change OS/process reserves or qualify a physical hardware tier.
/// This reads only safetensors headers — never the tensors — and mirrors the
/// exact key rule the sanitizer applies.
enum Qwen4ExpMmapFootprint {
    static let indexFileName = "model.safetensors.index.json"
    static let maximumHeaderBytes = 16 * 1024 * 1024
    static let maximumIndexBytes = 16 * 1024 * 1024

    /// Bytes to subtract from the on-disk weight size before the resident
    /// estimate; 0 for non-qwen4 models, when offload is off, or on any parse
    /// problem (fail closed to the conservative on-disk estimate).
    static func excludedBytes(
        snapshotDir: URL,
        modelType: String?,
        offloadEnabled: Bool = Qwen4ExpPLEResidency.useMmap
    ) -> UInt64 {
        guard offloadEnabled, let modelType,
            Qwen4ExpPLEResidency.qwen4ExpModelTypes.contains(
                modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return 0 }
        let indexURL = snapshotDir.appendingPathComponent(indexFileName)
        guard let indexData = boundedIndex(indexURL),
            let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let weightMap = index["weight_map"] as? [String: String]
        else { return 0 }
        let selected = weightMap.filter { Qwen4ExpWeightSanitizer.shouldDrop($0.key, mmapPLE: true)
            && !Qwen4ExpWeightSanitizer.shouldDrop($0.key, mmapPLE: false) }
        guard !selected.isEmpty else { return 0 }

        var headers: [String: Header] = [:]
        var ranges: [String: [Range<UInt64>]] = [:]
        var total: UInt64 = 0
        for (key, shard) in selected {
            // An index describes files directly in its snapshot, not arbitrary
            // paths. HF snapshot-file symlinks to blobs remain supported.
            guard !shard.isEmpty, shard == (shard as NSString).lastPathComponent,
                shard.hasSuffix(".safetensors") else { return 0 }
            let header: Header
            if let cached = headers[shard] {
                header = cached
            } else {
                guard let parsed = readHeader(snapshotDir.appendingPathComponent(shard)) else {
                    return 0
                }
                headers[shard] = parsed
                header = parsed
            }
            guard let entry = header.tensors[key] as? [String: Any],
                let offsets = entry["data_offsets"] as? [NSNumber], offsets.count == 2,
                let start = byteOffset(offsets[0]), let end = byteOffset(offsets[1]),
                end >= start, end <= header.payloadBytes
            else { return 0 }
            let range = start..<end
            guard !(ranges[shard] ?? []).contains(where: { $0.overlaps(range) })
            else { return 0 }
            ranges[shard, default: []].append(range)
            let (sum, overflow) = total.addingReportingOverflow(end - start)
            guard !overflow else { return 0 }
            total = sum
        }
        return total
    }

    private struct Header {
        let tensors: [String: Any]
        let payloadBytes: UInt64
    }

    private static func byteOffset(_ number: NSNumber) -> UInt64? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Reject negative and fractional JSON numbers; uint64Value alone
        // would wrap/truncate them and could understate load admission.
        return UInt64(number.stringValue)
    }

    private static func readHeader(_ url: URL) -> Header? {
        guard let handle = regularHandle(url) else { return nil }
        defer { try? handle.close() }
        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else {
            return nil
        }
        let headerLength = lengthData.withUnsafeBytes { raw -> UInt64 in
            raw.loadUnaligned(as: UInt64.self).littleEndian
        }
        guard headerLength > 0, headerLength <= UInt64(maximumHeaderBytes),
            let data = try? handle.read(upToCount: Int(headerLength)),
            data.count == Int(headerLength),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let fileBytes = try? handle.seekToEnd(),
            fileBytes >= 8 + headerLength else { return nil }
        let payloadBytes = fileBytes - 8 - headerLength
        // Validate ALL ranges, not just excluded ones. A malformed shard must
        // not disguise compute bytes as offloaded PLE through overlap or an
        // inflated range inconsistent with its shape/dtype.
        guard validTensorRanges(object, payloadBytes: payloadBytes) else { return nil }
        return Header(tensors: object, payloadBytes: payloadBytes)
    }

    private static func boundedIndex(_ url: URL) -> Data? {
        guard let handle = regularHandle(url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0, size <= maximumIndexBytes,
            (try? handle.seek(toOffset: 0)) != nil,
            let data = try? handle.read(upToCount: maximumIndexBytes + 1), data.count <= maximumIndexBytes
        else { return nil }
        return data
    }

    private static func validTensorRanges(_ tensors: [String: Any], payloadBytes: UInt64) -> Bool {
        let widths: [String: UInt64] = ["BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1,
            "I16": 2, "U16": 2, "F16": 2, "BF16": 2, "I32": 4, "U32": 4, "F32": 4,
            "I64": 8, "U64": 8, "F64": 8]
        var ranges: [Range<UInt64>] = []
        for (name, raw) in tensors where name != "__metadata__" {
            guard let tensor = raw as? [String: Any],
                let dtype = tensor["dtype"] as? String, var bytes = widths[dtype],
                let shape = tensor["shape"] as? [NSNumber], shape.count <= 8,
                let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2,
                let start = byteOffset(offsets[0]), let end = byteOffset(offsets[1]),
                end >= start, end <= payloadBytes
            else { return false }
            for dimension in shape {
                guard let size = byteOffset(dimension) else { return false }
                let (product, overflow) = bytes.multipliedReportingOverflow(by: size)
                guard !overflow else { return false }
                bytes = product
            }
            guard end - start == bytes else { return false }
            if end > start { ranges.append(start..<end) }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in sorted.indices.dropFirst() {
            if sorted[index].lowerBound < sorted[index - 1].upperBound { return false }
        }
        return true
    }

    /// Follow legitimate HF blob symlinks, but never block on a named pipe
    /// or read a device through a checkpoint filename. Verify the opened FD.
    private static func regularHandle(_ url: URL) -> FileHandle? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
