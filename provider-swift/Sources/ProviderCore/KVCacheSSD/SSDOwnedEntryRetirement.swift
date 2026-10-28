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

    /// Caller holds its index-publication/removal barrier. File leases also
    /// exclude a writer between rename and publication; busy entries wait for
    /// the next pass. Recheck status at removal, never from an earlier snapshot.
    static func reconcileMissingEntries(root: URL, index: SSDBlockIndex) {
        for tag in index.allTags() {
            let url = SSDBlockStore.fileURL(root: root, tag16Hex: tag.hexString)
            guard let access = SSDCheckpointFileCoordinator.shared.tryAcquire(to: url) else { continue }
            defer { access.release() }
            guard SSDBlockStore.indexedBlockFileStatus(at: url, under: root) != .regular else { continue }
            _ = index.remove(tag16: tag)
        }
    }

    /// Files retired under one hold of a store's removal lock and the epoch
    /// barrier. Lookups on the engine's submit thread read the epoch through
    /// that barrier and a donor's index publication waits on the removal lock,
    /// so a long TTL or budget sweep is retired in short holds. Each hold
    /// rereads the epoch record, so smaller slices slow the sweep.
    static let filesPerSlice = 16

    /// Retires `urls` a slice at a time through `retire`, which takes the
    /// locks and returns nil when the store refuses. Stops at the first
    /// refusal and returns what the earlier slices removed.
    static func removeInSlices(_ urls: [URL], retire: ([URL]) -> Result?) -> Result {
        var total = Result()
        var start = 0
        repeat {
            let end = min(start + filesPerSlice, urls.count)
            guard let part = retire(Array(urls[start ..< end])) else { break }
            total.removed.formUnion(part.removed)
            total.indexedBytesFreed += part.indexedBytesFreed
            total.externalChange = total.externalChange || part.externalChange
            start = end
        } while start < urls.count
        return total
    }

    /// Maintenance chooses TTL victims by mtime, which can trail the index: a
    /// complete-checkpoint reader rewrites it only while it holds the file
    /// alone. With `unusedSince`, an entry the index saw hit after that time
    /// stays, and its last hit is persisted for restart scans and later sweeps.
    static func remove(
        urls: [URL], root: URL, index: SSDBlockIndex, epochStore: SSDCacheEpochStore?,
        unusedSince: Int64? = nil
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
                if let unusedSince, let lastAccess = index.lastAccess(tag16: tag), lastAccess > unusedSince {
                    persistHit(lastAccess, at: url, under: root)
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

    /// Never moves an mtime back, and skips a rewrite that would only change
    /// ctime and so the identity that authenticated receipts pin.
    private static func persistHit(_ lastAccess: Int64, at url: URL, under root: URL) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard modified.map({ Int64($0.timeIntervalSince1970) < lastAccess }) ?? true else { return }
        SSDBlockStore.setAttributesIfSafe([.modificationDate: Date(timeIntervalSince1970: Double(lastAccess))],
                                        at: url, under: root)
    }
}
