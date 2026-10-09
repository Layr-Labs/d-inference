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

    struct Stats: Sendable, Equatable {
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
        let pageFiles: [SSDCheckpointPageFiles.File]
    }

    private struct OwnedTempFile {
        let url: URL
        let bytes: Int
        let modifiedAt: Int64?
    }

    private struct OwnedContents {
        var blocks: [OwnedFile] = []
        var tempFiles: [OwnedTempFile] = []
        var orphanPages: [SSDCheckpointPageFiles.File] = []
    }

    private let maintenanceLock = NSLock()
    // Heartbeat snapshots must not wait for filesystem traversal or epoch I/O.
    private let statsLock = NSLock()
    private var totals = Stats()

    func statsSnapshot() -> Stats { statsLock.withLock { totals } }
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
        tasksLock.withLock {
            guard periodicTasks[key] == nil else { return }
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
        }
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
            cleanPageOrphans(under: root)
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
                    if let retired = SSDDiskBudget.shared.retireActiveEntries(
                        root: modelRoot, urls: group.map(\.url)) {
                        removed.formUnion(retired)
                        continue
                    }
                    let mutation = {
                        for file in group {
                            guard let access = SSDCheckpointFileCoordinator.shared.tryAcquire(to: file.url) else { continue }
                            defer { access.release() }
                            if SSDBlockStore.removeItemIfSafe(at: file.url, under: root) {
                                SSDCheckpointPageFiles.remove(for: file.url)
                                removed.insert(file.url.standardizedFileURL.path)
                            }
                        }
                        SSDCheckpointPageFiles.removeOrphans(under: modelRoot)
                    }
                    let completed = SSDCacheEpochStore.performUnloadedDestructiveChange(
                            root: modelRoot, mutation)
                    if !completed {
                        // The body never runs unless its maintenance barrier succeeds.
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

            func physicalBytes(_ entries: [OwnedFile]) -> Int {
                var pages: [String: Int] = [:]
                var bytes = tempBytes
                for page in contents.orphanPages {
                    pages[page.physicalIdentity] = max(pages[page.physicalIdentity] ?? 0, page.bytes)
                }
                for file in entries {
                    bytes = SSDCheckpointPageFiles.saturatingAdd(bytes, file.bytes)
                    for page in file.pageFiles {
                        pages[page.physicalIdentity] = max(pages[page.physicalIdentity] ?? 0, page.bytes)
                    }
                }
                return pages.values.reduce(bytes, SSDCheckpointPageFiles.saturatingAdd)
            }
            var total = physicalBytes(files)
            let limit = max(0, budgetBytes)
            var retentionPriorities: [String: SSDEvictionPriority] = [:]
            if total > limit, SSDDiskBudget.shared.hasActiveUtilityRetentionStore {
                for group in Dictionary(grouping: files, by: { $0.modelRoot }).values {
                    guard let modelRoot = group.first?.modelRoot else { continue }
                    retentionPriorities.merge(SSDDiskBudget.shared.retentionPriorities(
                        root: modelRoot, urls: group.map(\.url), now: nowSeconds), uniquingKeysWith: { _, new in new })
                }
            }

            func priority(_ file: OwnedFile) -> SSDEvictionPriority {
                let measured = retentionPriorities[file.url.standardizedFileURL.path]
                return .init(probationary: measured?.probationary ?? false,
                    savedMillisPerByte: measured?.savedMillisPerByte ?? 0,
                    lastAccess: file.modifiedAt, tieBreak: file.url.path)
            }

            var attempted = Set<String>()
            while total > limit {
                let candidates = files.filter {
                    !attempted.contains($0.url.standardizedFileURL.path)
                }.sorted {
                    if retentionPriorities.isEmpty {
                        if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                        return $0.url.path < $1.url.path
                    }
                    return priority($0) < priority($1)
                }
                guard !candidates.isEmpty else { break }
                var planned: [OwnedFile] = []
                var plannedPaths = Set<String>()
                var projected = total
                for file in candidates where projected > limit {
                    planned.append(file)
                    plannedPaths.insert(file.url.path)
                    let remaining = files.filter { !plannedPaths.contains($0.url.path) }
                    projected = physicalBytes(remaining)
                    attempted.insert(file.url.standardizedFileURL.path)
                }
                let removed = removeOwned(planned)
                guard !removed.isEmpty else { continue }
                result.budgetEvicted += removed.count
                files.removeAll { removed.contains($0.url.standardizedFileURL.path) }
                total = physicalBytes(files)
            }
            result.bytesAfter = total
            statsLock.withLock {
                totals.ttlExpired += result.ttlExpired
                totals.budgetEvicted += result.budgetEvicted
                totals.tempFilesRemoved += result.tempFilesRemoved
            }
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

    private func cleanPageOrphans(under root: URL) {
        guard SSDBlockStore.isSafeMaintenanceRoot(root),
            let models = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for model in models where SSDBlockStore.isLowerHex(model.lastPathComponent, count: 12) {
            guard SSDBlockStore.isRealDirectory(model), SSDBlockStore.pathResolvesToItself(model),
                SSDCheckpointPageFiles.hasOrphans(under: model) else { continue }
            let mutation = { SSDCheckpointPageFiles.removeOrphans(under: model) }
            if SSDDiskBudget.shared.performActiveDestructiveChange(root: model, mutation) == nil {
                _ = SSDCacheEpochStore.performUnloadedDestructiveChange(root: model, mutation)
            }
        }
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
                    if url.pathExtension == SSDCheckpointPageFiles.directoryExtension {
                        let stem = url.deletingPathExtension().lastPathComponent
                        if SSDBlockStore.isLowerHex(stem, count: 32), stem.hasPrefix(fanout.lastPathComponent) {
                            let checkpoint = SSDBlockStore.fileURL(root: modelDir, tag16Hex: stem)
                            if SSDBlockStore.indexedBlockFileStatus(at: checkpoint, under: modelDir) != .regular {
                                contents.orphanPages.append(contentsOf: SSDCheckpointPageFiles.files(for: checkpoint))
                            }
                        }
                        continue
                    }
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
                        metadataReadable: (try? SSDBlockStore.readMetadataOnly(
                            from: url, maximumMetadataBytes: 1 << 20,
                            maximumWrappedDEKBytes: 60)) != nil,
                        pageFiles: SSDCheckpointPageFiles.files(for: url)))
                }
            }
        }
        return contents
    }
}
