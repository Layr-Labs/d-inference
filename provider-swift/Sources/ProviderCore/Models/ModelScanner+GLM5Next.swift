import Darwin
import Foundation
import ProviderCoreFoundation

extension ModelScanner {
    /// Raw same-directory profile: the tokenizer shipped in the weight snapshot.
    static func glm5NextLoadEstimate(
        snapshotDir: URL, sizeBytes: UInt64? = nil
    ) -> GLM5NextDiscoveryLoadFootprint.Estimate? {
        let root = snapshotDir.standardizedFileURL
        guard let files = GLM5NextDiscoveryInventory.files(at: root) else { return nil }
        // Reuse the existing regular-FD, bounded readers; no payload is read.
        guard let config = Qwen4ExpMmapFootprint.boundedIndex(
                root.appendingPathComponent("config.json"),
                maximumBytes: GLM5NextDiscoveryLoadFootprint.maximumConfigurationBytes),
            let index = Qwen4ExpMmapFootprint.boundedIndex(
                root.appendingPathComponent("model.safetensors.index.json"),
                maximumBytes: GLM5NextDiscoveryLoadFootprint.maximumIndexBytes),
            let estimate = GLM5NextDiscoveryLoadFootprint.estimate(
                configuration: config, index: index, files: files,
                readHeader: { name in
                    Qwen4ExpMmapFootprint.readHeader(root.appendingPathComponent(name)).map {
                        .init(tensors: $0.tensors, fileBytes: $0.fileBytes, payloadBytes: $0.payloadBytes)
                    }
                }), sizeBytes == nil || estimate.storedBytes == sizeBytes
        else { return nil }
        // Detect changed sizes/inventory across metadata reads. Actual source
        // identity and payload verification remain the managed loader's job.
        guard GLM5NextDiscoveryInventory.files(at: root) == files else { return nil }
        return estimate
    }

    /// Bridge pre-allocation recheck against the raw same-directory quote.
    static func glm5NextLoadQuotationIsCurrent(_ info: ModelInfo, directory: URL) -> Bool {
        guard info.modelType == "glm5_next", (info.ssdOffloadedWeightBytes ?? 0) == 0,
            info.estimatedMemoryGb.isFinite,
            let estimate = glm5NextLoadEstimate(
                snapshotDir: directory, sizeBytes: info.sizeBytes),
            let supplement = info.nativeLoadTransientBytes,
            supplement >= estimate.supplementBytes,
            info.estimatedMemoryGb >= Double(estimate.totalBytes) / 1_073_741_824
        else { return false }
        return true
    }
}

/// Model payload stays flat, but HF cache bookkeeping and provenance receipts
/// may be nested. Walk every entry, including hidden entries, without following
/// symlinks; ignored metadata never contributes bytes to the model quotation.
private enum GLM5NextDiscoveryInventory {
    private enum Refusal: Error { case inventory }
    private static let maximumEntries = 4096
    private static let maximumDirectoryDepth = 8
    private static let maximumMetadataFileBytes: UInt64 = 32 << 20
    private static let maximumMetadataBytes: UInt64 = 64 << 20

    static func files(at root: URL) -> [String: UInt64]? {
        guard root.isFileURL, !root.path.utf8.contains(0) else { return nil }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var files: [String: UInt64] = [:]
        var visited = 0
        var metadataBytes: UInt64 = 0
        do {
            // walk owns this descriptor, including all failure paths.
            try walk(fd, depth: 0, files: &files, visited: &visited, metadataBytes: &metadataBytes)
            return files
        } catch { return nil }
    }

    private static func walk(
        _ fd: Int32, depth: Int, files: inout [String: UInt64],
        visited: inout Int, metadataBytes: inout UInt64
    ) throws {
        guard let directory = fdopendir(fd) else {
            close(fd)
            throw Refusal.inventory
        }
        defer { closedir(directory) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Refusal.inventory }
                return
            }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { bytes in
                String(validatingCString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }) else { throw Refusal.inventory }
            if name == "." || name == ".." { continue }
            visited += 1
            guard visited <= maximumEntries else { throw Refusal.inventory }
            var state = stat()
            guard fstatat(fd, name, &state, AT_SYMLINK_NOFOLLOW) == 0 else { throw Refusal.inventory }
            let integrity = ModelScanner.isIntegrityFile(name)
            switch state.st_mode & S_IFMT {
            case S_IFDIR:
                guard !integrity, depth < maximumDirectoryDepth else { throw Refusal.inventory }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard child >= 0 else { throw Refusal.inventory }
                try walk(child, depth: depth + 1, files: &files, visited: &visited, metadataBytes: &metadataBytes)
            case S_IFREG:
                guard state.st_size >= 0 else { throw Refusal.inventory }
                let bytes = UInt64(state.st_size)
                if integrity {
                    guard depth == 0, bytes > 0 else { throw Refusal.inventory }
                    files[name] = bytes
                } else {
                    guard bytes <= maximumMetadataFileBytes,
                        bytes <= maximumMetadataBytes - metadataBytes else { throw Refusal.inventory }
                    metadataBytes += bytes
                }
            default:
                // Symlinks (even to harmless receipts), FIFOs and devices are
                // not metadata directories/files and must not be traversed.
                throw Refusal.inventory
            }
        }
    }
}
