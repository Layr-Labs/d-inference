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

    /// What reading a block file's header says about the file.
    enum HeaderRead: Sendable {
        /// A readable header of this format: the file is counted.
        case owned
        /// The header was read and is not one of ours, or the path is not a
        /// plain file under real directories: left alone and not counted.
        case notOwned
        /// The file went away since its directory was listed.
        case gone
        /// The file is there and its header could not be opened or read.
        case unreadable
    }

    /// Reads a directory entry's attributes; nil when they cannot be read.
    /// Replaceable in tests, as `readHeader` is.
    private let readAttributes: @Sendable (URL, Set<URLResourceKey>) -> URLResourceValues?
    private let readHeader: @Sendable (URL) -> HeaderRead

    /// A whole pass that was disturbed cannot make an unknown root known,
    /// so the root is walked again, at most this many times in one pass.
    static let maximumWalksPerPass = 3

    init(
        readAttributes: @escaping @Sendable (URL, Set<URLResourceKey>) -> URLResourceValues? = {
            try? $0.resourceValues(forKeys: $1)
        },
        readHeader: @escaping @Sendable (URL) -> HeaderRead = { SSDWholeRootMaintainer.header(of: $0) }
    ) {
        self.readAttributes = readAttributes
        self.readHeader = readHeader
    }

    /// An entry that is there and cannot be read means the walk has not
    /// seen everything. One that went away since it was listed does not.
    static func isGone(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) != 0 && errno == ENOENT
    }

    static func header(of url: URL) -> HeaderRead {
        do {
            _ = try SSDBlockStore.readMetadataOnly(
                from: url, maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60)
            return .owned
        } catch let error as SSDBlockStoreError {
            switch error {
            case .malformedHeader, .unsupportedVersion, .authenticationFailed, .sizeOverflow, .truncated,
                .bindingMismatch:
                return .notOwned
            case .posixFailure(_, let code):
                return code == ENOENT ? .gone : .unreadable
            case .ioFailure:
                // Thrown for a path that is not a plain file under real
                // directories, and for a file that could not be read. Only
                // what `lstat` itself shows is taken as proof of the former.
                var status = stat()
                guard lstat(url.path, &status) == 0 else { return errno == ENOENT ? .gone : .unreadable }
                guard status.st_mode & S_IFMT == S_IFREG else { return .notOwned }
                return SSDBlockStore.isSafeBlockURL(url) ? .unreadable : .notOwned
            }
        } catch {
            return isGone(url) ? .gone : .unreadable
        }
    }

    private struct OwnedFile {
        let url: URL
        let modelRoot: URL
        let bytes: Int
        let modifiedAt: Int64
        let metadataReadable: Bool
        /// `SSDDiskBudget.rootKey` of `modelRoot`, resolved once per directory.
        let modelRootKey: String
        /// `SSDDiskBudget.reservationKey` of the write that would own it.
        let key: String
    }

    private struct OwnedTempFile {
        let url: URL
        let bytes: Int
        let modifiedAt: Int64?
        let key: String
    }

    private struct OwnedContents {
        var blocks: [OwnedFile] = []
        var tempFiles: [OwnedTempFile] = []
        /// False when the root, a model directory or a fan-out could not be
        /// listed, or an entry's attributes or size could not be read: the
        /// walk then saw less than is on disk.
        var complete = true
    }

    private let maintenanceLock = NSLock()
    // Heartbeat snapshots must not wait for filesystem traversal or epoch I/O.
    private let statsLock = NSLock()
    private var totals = Stats()

    func statsSnapshot() -> Stats { statsLock.withLock { totals } }
    private let tasksLock = NSLock()
    private var periodicTasks: [String: Task<Void, Never>] = [:]
    private var periodicBases: [String: @Sendable () -> SSDDiskBudgetBasis] = [:]

    /// How the periodic pass over `root` resolves its budget, or nil when
    /// none is running or it was started with a plain byte count.
    func periodicBudgetBasis(root: URL) -> (@Sendable () -> SSDDiskBudgetBasis)? {
        tasksLock.withLock { periodicBases[root.standardizedFileURL.path] }
    }

    func startPeriodicMaintenance(
        root: URL,
        ttlSeconds: Int64,
        intervalSeconds: Int = 60,
        nowSeconds: @escaping @Sendable () -> Int64,
        budgetBytes: @escaping @Sendable () -> Int,
        budgetBasis: (@Sendable () -> SSDDiskBudgetBasis)? = nil,
        budget: SSDDiskBudget = .shared
    ) {
        let key = root.standardizedFileURL.path
        tasksLock.withLock {
            guard periodicTasks[key] == nil else { return }
            periodicBases[key] = budgetBasis
            periodicTasks[key] = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    _ = self?.maintain(
                        root: root, ttlSeconds: ttlSeconds, nowSeconds: nowSeconds(), budget: budget,
                        basis: budgetBasis ?? { .fixed(budgetBytes()) })
                    budget.reconcileAll()
                    try? await taskSleep(.seconds(max(1, intervalSeconds)))
                }
            }
        }
    }

    /// A pass against a budget that was resolved by the caller. `budgetBasis`
    /// says how; nil means the budget does not move with the volume.
    @discardableResult
    func maintain(
        root: URL,
        ttlSeconds: Int64,
        nowSeconds: Int64,
        budgetBytes: Int,
        budget: SSDDiskBudget = .shared,
        budgetBasis: SSDDiskBudgetBasis? = nil
    ) -> Result {
        maintain(root: root, ttlSeconds: ttlSeconds, nowSeconds: nowSeconds, budget: budget,
                 basis: { budgetBasis ?? .fixed(budgetBytes) })
    }

    /// `budget` is the ledger of the stores under `root`: the pass retires
    /// active entries through it, learns from it which temp and not-yet-
    /// indexed files belong to in-flight speculative writes, and publishes to
    /// it the bytes that no registered index counts. `basis` resolves the
    /// budget; it is called once the pass holds its lock and its observation
    /// window is open, so a speculative write whose bytes are in that reading
    /// of the volume is known to the window even if it is gone before the
    /// walk reaches its directory.
    @discardableResult
    func maintain(
        root: URL,
        ttlSeconds: Int64,
        nowSeconds: Int64,
        budget: SSDDiskBudget = .shared,
        basis resolveBasis: () -> SSDDiskBudgetBasis
    ) -> Result {
        maintenanceLock.withLock {
            let rootKey = SSDDiskBudget.rootKey(root)
            var total = Result()
            // Walked again only when a whole walk ended disturbed with the
            // root still unknown: writers that keep committing must not keep
            // first sight off for good.
            for _ in 0..<Self.maximumWalksPerPass {
                let (result, complete) = walkOnce(
                    root: root, rootKey: rootKey, ttlSeconds: ttlSeconds, nowSeconds: nowSeconds, budget: budget,
                    basis: resolveBasis)
                total.filesSeen = result.filesSeen
                total.bytesAfter = result.bytesAfter
                total.ttlExpired += result.ttlExpired
                total.budgetEvicted += result.budgetEvicted
                total.tempFilesRemoved += result.tempFilesRemoved
                if !complete || budget.isOccupancyKnown(wholeRootKey: rootKey) { break }
            }
            statsLock.withLock {
                totals.ttlExpired += total.ttlExpired
                totals.budgetEvicted += total.budgetEvicted
                totals.tempFilesRemoved += total.tempFilesRemoved
            }
            return total
        }
    }

    private func walkOnce(
        root: URL, rootKey: String, ttlSeconds: Int64, nowSeconds: Int64, budget: SSDDiskBudget,
        basis resolveBasis: () -> SSDDiskBudgetBasis
    ) -> (Result, complete: Bool) {
        var result = Result()
        // The window covers the walk, so a write that starts or ends
        // while the tree is read is still recognised below.
        let window = budget.beginWholeRootObservation(wholeRootKey: rootKey)
        let budgetBasis = resolveBasis()
        let budgetBytes = budgetBasis.bytes()
        let contents = ownedContents(under: root)
        let inFlight = budget.endWholeRootObservation(window)
        var tempBytes = 0
        // A speculative write was granted only free room, so its bytes
        // must never be the reason a committed entry is evicted. They
        // are kept out of the total; if the root is over its limit only
        // with them, those writes are told to stop instead.
        var speculativeBytes = 0
        var unreservedTempBytes = 0
        for file in contents.tempFiles {
            if SSDBlockStore.isStaleTempFile(
                modifiedAt: file.modifiedAt, nowSeconds: nowSeconds),
                SSDBlockStore.removeItemIfSafe(at: file.url, under: root)
            {
                result.tempFilesRemoved += 1
            } else if inFlight.speculativeKeys.contains(file.key) {
                speculativeBytes += file.bytes
            } else {
                tempBytes += file.bytes
                if !inFlight.reservedKeys.contains(file.key) { unreservedTempBytes += file.bytes }
            }
        }
        // Header readability is the ownership proof. Exact-looking but
        // malformed files are left untouched, including by budget eviction.
        // A speculative write's published file is not a committed entry
        // until its writer indexes it, and may still be withdrawn.
        var files = contents.blocks.filter { file in
            guard file.metadataReadable else { return false }
            guard inFlight.speculativeKeys.contains(file.key) else { return true }
            speculativeBytes += file.bytes
            return false
        }
        result.filesSeen = files.count

        func removeOwned(_ candidates: [OwnedFile]) -> Set<String> {
            var removed = Set<String>()
            let groups = Dictionary(grouping: candidates) {
                $0.modelRoot.standardizedFileURL.resolvingSymlinksInPath().path
            }
            for group in groups.values {
                guard let modelRoot = group.first?.modelRoot else { continue }
                if let retired = budget.retireActiveEntries(
                    root: modelRoot, urls: group.map(\.url)) {
                    removed.formUnion(retired)
                    continue
                }
                let mutation = {
                    for file in group where
                        SSDBlockStore.removeItemIfSafe(at: file.url, under: root)
                    {
                        removed.insert(file.url.standardizedFileURL.path)
                    }
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

        var total = files.reduce(tempBytes) { $0 + $1.bytes }
        var limit = max(0, budgetBytes)
        if speculativeBytes > 0, total > limit - min(limit, speculativeBytes) {
            budget.revokeSpeculativeWrites()
        }
        // Those bytes were on the volume when the budget was read, where
        // they lowered a half-of-free budget, whether or not the walk
        // still found them. Entries are evicted only against the limit
        // that holds without them.
        let credited = max(speculativeBytes, inFlight.speculativeLandedBytes)
        if credited > 0 { limit = max(0, budgetBasis.bytes(afterRemoving: credited)) }
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
        // A walk that could not list everything saw too little: it may
        // raise the published figure and not lower it.
        budget.publishWholeRoot(
            wholeRootKey: rootKey,
            bytesByModelRoot: files.reduce(into: [:]) { bytes, file in
                bytes[file.modelRootKey, default: 0] += file.bytes
            },
            unreservedTempBytes: unreservedTempBytes, observation: inFlight, complete: contents.complete)
        return (result, contents.complete)
    }

    func stopPeriodicMaintenance(root: URL) {
        let key = root.standardizedFileURL.path
        let task = tasksLock.withLock { () -> Task<Void, Never>? in
            periodicBases.removeValue(forKey: key)
            return periodicTasks.removeValue(forKey: key)
        }
        task?.cancel()
    }

    func stopAllPeriodicMaintenanceForTesting() {
        let tasks = tasksLock.withLock { () -> [Task<Void, Never>] in
            let values = Array(periodicTasks.values)
            periodicTasks.removeAll()
            periodicBases.removeAll()
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
        else { return OwnedContents(complete: false) }

        var contents = OwnedContents()
        for modelDir in modelDirs {
            guard SSDBlockStore.isLowerHex(modelDir.lastPathComponent, count: 12) else { continue }
            // An entry whose attributes cannot be read may be a directory
            // with files in it: the walk has then not seen everything.
            guard let modelValues = readAttributes(modelDir, [.isDirectoryKey, .isSymbolicLinkKey])
            else { if !Self.isGone(modelDir) { contents.complete = false }; continue }
            guard modelValues.isDirectory == true, modelValues.isSymbolicLink != true else { continue }
            guard let fanouts = try? fm.contentsOfDirectory(
                at: modelDir,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else { if !Self.isGone(modelDir) { contents.complete = false }; continue }
            let modelRootKey = SSDDiskBudget.rootKey(modelDir)
            for fanout in fanouts {
                guard SSDBlockStore.isLowerHex(fanout.lastPathComponent, count: 2) else { continue }
                guard let fanoutValues = readAttributes(fanout, [.isDirectoryKey, .isSymbolicLinkKey])
                else { if !Self.isGone(fanout) { contents.complete = false }; continue }
                guard fanoutValues.isDirectory == true, fanoutValues.isSymbolicLink != true else { continue }
                guard let entries = try? fm.contentsOfDirectory(
                    at: fanout,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles])
                else { if !Self.isGone(fanout) { contents.complete = false }; continue }
                for url in entries {
                    guard let values = readAttributes(url, keys)
                    else { if !Self.isGone(url) { contents.complete = false }; continue }
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    // Counted as empty below; its real size is not known.
                    if values.fileSize == nil { contents.complete = false }
                    if SSDBlockStore.isOwnedTempFileName(
                        url.lastPathComponent, fanout: fanout.lastPathComponent)
                    {
                        contents.tempFiles.append(OwnedTempFile(
                            url: url,
                            bytes: max(0, values.fileSize ?? 0),
                            modifiedAt: values.contentModificationDate.map {
                                Int64($0.timeIntervalSince1970)
                            },
                            key: SSDDiskBudget.reservationKey(
                                modelRootKey: modelRootKey, tag16Hex: String(url.lastPathComponent.prefix(32)))))
                        continue
                    }
                    let stem = url.deletingPathExtension().lastPathComponent
                    guard url.pathExtension == SSDBlockStore.fileExtension,
                        SSDBlockStore.isLowerHex(stem, count: 32),
                        stem.hasPrefix(fanout.lastPathComponent)
                    else { continue }
                    // A header that could not be read is not proof that the
                    // file is not ours: its bytes may be missing from the total.
                    let header = readHeader(url)
                    if header == .gone { continue }
                    if header == .unreadable { contents.complete = false }
                    contents.blocks.append(OwnedFile(
                        url: url,
                        modelRoot: modelDir,
                        bytes: max(0, values.fileSize ?? 0),
                        modifiedAt: Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                        metadataReadable: header == .owned,
                        modelRootKey: modelRootKey,
                        key: SSDDiskBudget.reservationKey(modelRootKey: modelRootKey, tag16Hex: stem)))
                }
            }
        }
        return contents
    }
}
