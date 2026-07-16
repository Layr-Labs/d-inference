import Foundation

/// Unloaded-model maintenance for the dedicated `darkbloom/kv3` root.
/// It inspects only the exact hierarchy produced by `SSDBlockStore` and never
/// loads model weights or KV arrays.
final class SSDWholeRootMaintainer: @unchecked Sendable {
    struct Result: Sendable, Equatable {
        var filesSeen = 0
        var bytesAfter = 0
        var ttlExpired = 0
        var budgetEvicted = 0
        var tempFilesRemoved = 0
    }

    static let shared = SSDWholeRootMaintainer()

    private struct OwnedFile {
        let url: URL
        let modelRoot: URL
        let bytes: Int
        let modifiedAt: Int64
        let metadataReadable: Bool
    }

    private struct OwnedTempFile {
        let url: URL
        let bytes: Int
        let modifiedAt: Int64?
    }

    private struct OwnedContents {
        var blocks: [OwnedFile] = []
        var tempFiles: [OwnedTempFile] = []
    }

    private let maintenanceLock = NSLock()
    private let tasksLock = NSLock()
    private var periodicTasks: [String: Task<Void, Never>] = [:]

    func startPeriodicMaintenance(
        root: URL,
        ttlSeconds: Int64,
        intervalSeconds: Int = 60,
        nowSeconds: @escaping @Sendable () -> Int64,
        budgetBytes: @escaping @Sendable () -> Int
    ) {
        let key = root.standardizedFileURL.path
        let shouldStart = tasksLock.withLock { () -> Bool in
            guard periodicTasks[key] == nil else { return false }
            periodicTasks[key] = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    _ = self?.maintain(
                        root: root,
                        ttlSeconds: ttlSeconds,
                        nowSeconds: nowSeconds(),
                        budgetBytes: budgetBytes())
                    SSDDiskBudget.shared.reconcileAll()
                    try? await taskSleep(.seconds(max(1, intervalSeconds)))
                }
            }
            return true
        }
        if !shouldStart { return }
    }

    @discardableResult
    func maintain(
        root: URL,
        ttlSeconds: Int64,
        nowSeconds: Int64,
        budgetBytes: Int
    ) -> Result {
        maintenanceLock.withLock {
            var result = Result()
            let contents = ownedContents(under: root)
            var tempBytes = 0
            for file in contents.tempFiles {
                if SSDBlockStore.isStaleTempFile(
                    modifiedAt: file.modifiedAt, nowSeconds: nowSeconds),
                    SSDBlockStore.removeItemIfSafe(at: file.url, under: root)
                {
                    result.tempFilesRemoved += 1
                } else {
                    tempBytes += file.bytes
                }
            }
            // Header readability is the ownership proof. Exact-looking but
            // malformed files are left untouched, including by budget eviction.
            var files = contents.blocks.filter(\.metadataReadable)
            result.filesSeen = files.count

            func removeOwned(_ candidates: [OwnedFile]) -> Set<String> {
                var removed = Set<String>()
                let groups = Dictionary(grouping: candidates) {
                    $0.modelRoot.standardizedFileURL.resolvingSymlinksInPath().path
                }
                for group in groups.values {
                    guard let modelRoot = group.first?.modelRoot else { continue }
                    let mutation = {
                        for file in group where
                            SSDBlockStore.removeItemIfSafe(at: file.url, under: root)
                        {
                            removed.insert(file.url.standardizedFileURL.path)
                        }
                    }
                    let completed =
                        SSDDiskBudget.shared.performActiveDestructiveChange(
                            root: modelRoot, mutation)
                        ?? SSDCacheEpochStore.performUnloadedDestructiveChange(
                            root: modelRoot, mutation)
                    if !completed {
                        // The body never runs unless its epoch barrier succeeds.
                        continue
                    }
                }
                return removed
            }

            if ttlSeconds > 0 {
                let expired = files.filter {
                    nowSeconds - $0.modifiedAt >= ttlSeconds
                }
                let removed = removeOwned(expired)
                result.ttlExpired = removed.count
                files.removeAll {
                    removed.contains($0.url.standardizedFileURL.path)
                }
            }

            var total = files.reduce(tempBytes) { $0 + $1.bytes }
            let limit = max(0, budgetBytes)
            var attempted = Set<String>()
            while total > limit {
                let candidates = files.filter {
                    !attempted.contains($0.url.standardizedFileURL.path)
                }.sorted {
                    if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                    return $0.url.path < $1.url.path
                }
                guard !candidates.isEmpty else { break }
                var planned: [OwnedFile] = []
                var projected = total
                for file in candidates where projected > limit {
                    planned.append(file)
                    projected = max(0, projected - file.bytes)
                    attempted.insert(file.url.standardizedFileURL.path)
                }
                let removed = removeOwned(planned)
                guard !removed.isEmpty else { continue }
                let freed = files.reduce(0) { bytes, file in
                    removed.contains(file.url.standardizedFileURL.path)
                        ? bytes + file.bytes : bytes
                }
                result.budgetEvicted += removed.count
                total = max(0, total - freed)
                files.removeAll {
                    removed.contains($0.url.standardizedFileURL.path)
                }
            }
            result.bytesAfter = total
            return result
        }
    }

    func stopPeriodicMaintenance(root: URL) {
        let key = root.standardizedFileURL.path
        let task = tasksLock.withLock { periodicTasks.removeValue(forKey: key) }
        task?.cancel()
    }

    func stopAllPeriodicMaintenanceForTesting() {
        let tasks = tasksLock.withLock { () -> [Task<Void, Never>] in
            let values = Array(periodicTasks.values)
            periodicTasks.removeAll()
            return values
        }
        for task in tasks { task.cancel() }
    }

    private func ownedContents(under root: URL) -> OwnedContents {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        guard SSDBlockStore.isSafeMaintenanceRoot(root),
            let modelDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return OwnedContents() }

        var contents = OwnedContents()
        for modelDir in modelDirs {
            guard SSDBlockStore.isLowerHex(modelDir.lastPathComponent, count: 12),
                let modelValues = try? modelDir.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                modelValues.isDirectory == true, modelValues.isSymbolicLink != true,
                let fanouts = try? fm.contentsOfDirectory(
                    at: modelDir,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles])
            else { continue }
            for fanout in fanouts {
                guard SSDBlockStore.isLowerHex(fanout.lastPathComponent, count: 2),
                    let fanoutValues = try? fanout.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                    fanoutValues.isDirectory == true, fanoutValues.isSymbolicLink != true,
                    let entries = try? fm.contentsOfDirectory(
                        at: fanout,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles])
                else { continue }
                for url in entries {
                    guard let values = try? url.resourceValues(forKeys: keys),
                        values.isRegularFile == true, values.isSymbolicLink != true
                    else { continue }
                    if SSDBlockStore.isOwnedTempFileName(
                        url.lastPathComponent, fanout: fanout.lastPathComponent)
                    {
                        contents.tempFiles.append(OwnedTempFile(
                            url: url,
                            bytes: max(0, values.fileSize ?? 0),
                            modifiedAt: values.contentModificationDate.map {
                                Int64($0.timeIntervalSince1970)
                            }))
                        continue
                    }
                    let stem = url.deletingPathExtension().lastPathComponent
                    guard url.pathExtension == SSDBlockStore.fileExtension,
                        SSDBlockStore.isLowerHex(stem, count: 32),
                        stem.hasPrefix(fanout.lastPathComponent)
                    else { continue }
                    contents.blocks.append(OwnedFile(
                        url: url,
                        modelRoot: modelDir,
                        bytes: max(0, values.fileSize ?? 0),
                        modifiedAt: Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                        metadataReadable: (try? SSDBlockStore.readMetadataOnly(from: url)) != nil))
                }
            }
        }
        return contents
    }
}
