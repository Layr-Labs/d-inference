import Foundation

/// Exact-path, no-follow retirement shared by attention and complete stores.
/// This never authenticates or advertises bytes. Unexpected external removal
/// remains a separate destructive-reconciliation event in the owning store.
enum SSDOwnedEntryRetirement {
    struct Result {
        var removed: Set<String> = []
        var indexedBytesFreed = 0
        var externalChange = false
    }

    static func remove(
        urls: [URL], root: URL, index: SSDBlockIndex, epochStore: SSDCacheEpochStore?
    ) -> Result? {
        let body = {
            var result = Result()
            for url in urls {
                guard let tag = SSDPrefixCache.hexDecode(url.deletingPathExtension().lastPathComponent),
                    tag.count == 16,
                    url.standardizedFileURL == SSDBlockStore.fileURL(root: root, tag16Hex: tag.hexString).standardizedFileURL
                else { continue }
                // A rename is visible before its writer inserts the index.
                // Share the writer/read-stage lease, and never block under the
                // epoch barrier. Deleting an uncommitted file would otherwise
                // allow that writer to advertise a missing checkpoint later.
                guard let access = SSDCheckpointFileCoordinator.shared.tryAcquire(to: url) else { continue }
                defer { access.release() }
                guard SSDBlockStore.indexedBlockFileStatus(at: url, under: root) == .regular else {
                    result.externalChange = result.externalChange || index.contains(tag16: tag)
                    continue
                }
                if SSDBlockStore.removeItemIfSafe(at: url, under: root) {
                    result.indexedBytesFreed += index.remove(tag16: tag)
                    result.removed.insert(url.standardizedFileURL.path)
                } else if SSDBlockStore.indexedBlockFileStatus(at: url, under: root) != .regular {
                    result.externalChange = result.externalChange || index.contains(tag16: tag)
                }
            }
            return result
        }
        if let epochStore { return epochStore.performOwnedRetirement(body) }
        return body()
    }
}
