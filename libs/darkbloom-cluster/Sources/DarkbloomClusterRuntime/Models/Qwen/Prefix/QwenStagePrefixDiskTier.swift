import Darwin
import Foundation
import MLX

/// Qualification-only faults of a disk restore. They exist only in a process
/// started with the explicit qualification flag (`QwenPhaseSplitFault`).
struct QwenStagePrefixDiskFault: Equatable {
    /// The restore fails after its header was read, as an unreadable record would.
    var restoreFails = false
    /// The restore stops this long halfway through its units, still checking
    /// the request (a stalled disk); a peer or owner fault ends it there.
    var restoreStallMilliseconds: Int?
}

/// The SSD tier of one rank's prompt-prefix cache (the owner's design: per
/// rank, per plan; boundary chains per prompt; unanimous boundary vote; sweep
/// on every rank; restore on both or neither).
///
/// Layout: `<root>/v1-<plan scope digest>/rank<r>/<keyed name>.dbpx`. The plan
/// scope is the plan fingerprint, the verified artifact, the storage
/// commitment and both ranks' builds: a re-split, another model or a new build
/// gets a new directory, and at load every rank deletes the directories of
/// other plans under its root (deleted deployments never leave orphans).
///
/// A record is one prompt's state on this rank: its attention rows up to the
/// prompt's deepest kept frontier (N-1) and its recurrent state at each kept
/// frontier (N-1 and the frontiers on a coarse grid). A frontier is offered to
/// the peer only when its record is complete on disk; both ranks then choose
/// the deepest frontier both offer, exactly as for the resident tier, and
/// confirm the restore before the first forward, so a rank that cannot read
/// its record makes both ranks prefill from zero.
///
/// Records are written behind serving on one serial writer, after the request
/// retired cleanly on both ranks; a persist beyond the queue bounds is
/// dropped, never waited for. Eviction is least recently used by record count
/// (identical on both ranks, whose operations are identical), then by bytes
/// against this rank's budget (a safety bound that may differ between ranks:
/// a frontier one rank no longer holds is simply not chosen). Records expire
/// after the sliding TTL (30 minutes maximum, as the product's SSD tier).
/// Writes stop below the free-space floor and the daily write cap.
public final class QwenStagePrefixDiskTier: @unchecked Sendable {
    struct Record {
        let name: String
        let scope: String
        let recordKey: String
        let committedTokens: Int
        /// Kept frontier -> its shared key.
        let frontiers: [Int: String]
        var bytes: Int
        var lastUse: UInt64
        var lastUseTime: TimeInterval
        var written: Bool
    }
    public struct Statistics: Equatable, Sendable {
        public var loadedRecords = 0
        public var sweptPlans = 0
        public var sweptFiles = 0
        public var restores = 0
        public var failedRestores = 0
        public var restoredBytes = 0
        public var persisted = 0
        public var persistedBytes = 0
        public var droppedPersists = 0
        public var evictions = 0
        public var expirations = 0
        /// Teardown: whether `close` waited past its bound once because a
        /// write had just completed (progress), and whether it ended drained.
        public var closeExtended = false
        public var closeDrained = true
    }

    public let configuration: QwenStagePrefixDiskConfiguration
    let keys: QwenStagePrefixDiskKeys
    let root: URL
    let planDirectory: URL
    let directory: URL
    let rank: Int
    var fault: QwenStagePrefixDiskFault?
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var byKey: [String: String] = [:]
    private var pinned: Set<String> = []
    private var clock: UInt64 = 0
    private let queue = DispatchQueue(label: "darkbloom.cluster.prefix-ssd.writer")
    /// A shared lock on `<plan directory>/in-use`, held for this process's
    /// life: another worker's sweep skips a plan directory a live rank uses.
    private var inUse: Int32 = -1
    private let group = DispatchGroup()
    private var queuedJobs = 0
    private var queuedBytes = 0
    private var cancelled = false
    private var writeWindowStart: TimeInterval = 0
    private var writeWindowBytes = 0
    /// When the writer last finished a record (progress, for `close`).
    private var lastCompletedWrite: TimeInterval?
    private var statistics = Statistics()
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    public var stats: Statistics { lock.withLock { statistics } }
    public var recordCount: Int { lock.withLock { records.values.filter(\.written).count } }

    /// Grid frontiers one record keeps at most, besides the prompt's N-1.
    static let maximumGridFrontiers = 8

    static func planDirectoryName(scope: String) -> String { "v1-" + String(sha256(Data(scope.utf8)).prefix(24)) }
    static func isPlanDirectoryName(_ name: String) -> Bool {
        name.count == 27 && name.hasPrefix("v1-") && name.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The scope of a plan's directory, from what each rank knows at load:
    /// the plan, the verified artifact and storage, both ranks' builds, and the
    /// generation mode and prefill schedule the pair was loaded with (records
    /// are never shared across modes; a mode change starts a new directory).
    static func planScope(planFingerprint: String, artifactAggregateSHA256: String, storageCommitmentSHA256: String,
                          rankBuildSHA256: [String], generationMode: String = "", prefillSchedule: String = "") -> String {
        (["darkbloom-cluster-prefix-ssd-v1", planFingerprint, artifactAggregateSHA256, storageCommitmentSHA256]
            + rankBuildSHA256 + ["mode=" + generationMode, "prefill=" + prefillSchedule]).joined(separator: "|")
    }

    /// Opens this rank's tier, or nil when it is off. Either way, directories
    /// of other plans under the root (all of them when off) are deleted first.
    static func open(configuration: QwenStagePrefixDiskConfiguration, planScope: String, rank: Int,
                     fault: QwenStagePrefixDiskFault? = nil) -> QwenStagePrefixDiskTier? {
        switch configuration.mode {
        case .off(let sweepRoot, let reason):
            var swept = 0
            if let sweepRoot { swept = sweepPlans(root: sweepRoot, keeping: nil) }
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=off reason=\(qwenPrefixLogWord(reason)) swept_plans=\(swept)")
            return nil
        case .on(let root, let key):
            do {
                return try QwenStagePrefixDiskTier(configuration: configuration, root: root, key: key,
                    planScope: planScope, rank: rank, fault: fault)
            } catch {
                log("darkbloom-prefix-ssd-v1 rank=\(rank) event=unavailable error=\(qwenPrefixLogWord(error))")
                return nil
            }
        }
    }

    init(configuration: QwenStagePrefixDiskConfiguration, root: URL, key: Data, planScope: String, rank: Int,
         fault: QwenStagePrefixDiskFault? = nil) throws {
        guard (0...63).contains(rank) else { throw ProbeError("Prefix SSD rank is out of range") }
        self.configuration = configuration; self.keys = QwenStagePrefixDiskKeys(master: key)
        self.root = root; self.rank = rank; self.fault = fault
        let planName = Self.planDirectoryName(scope: planScope)
        planDirectory = root.appendingPathComponent(planName, isDirectory: true)
        directory = planDirectory.appendingPathComponent("rank\(rank)", isDirectory: true)
        let start = DispatchTime.now().uptimeNanoseconds
        try Self.makePrivateDirectory(root)
        let sweptPlans = Self.sweepPlans(root: root, keeping: planName)
        try Self.makePrivateDirectory(planDirectory)
        inUse = Darwin.open(planDirectory.appendingPathComponent("in-use").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        if inUse >= 0 { _ = flock(inUse, LOCK_SH) }
        try Self.makePrivateDirectory(directory)
        statistics.sweptPlans = sweptPlans
        loadIndex()
        let loaded = records.count
        statistics.loadedRecords = loaded
        evictOverLimits(protecting: nil)
        let bytes = lock.withLock { records.values.reduce(0) { $0 + $1.bytes } }
        log("darkbloom-prefix-ssd-v1 rank=\(rank) event=open plan=\(planName) records=\(recordCount) bytes=\(bytes)"
            + " swept_plans=\(sweptPlans) swept_files=\(statistics.sweptFiles) expired=\(statistics.expirations)"
            + " ms=\((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
    }

    // MARK: lookup and restore

    /// Frontiers whose record is complete and live, at most `maximumFrontier`,
    /// deepest first. Does not touch recency.
    func frontiers(scope: String, tokens: [Int], maximumFrontier: Int) -> [Int] {
        let time = now()
        let candidates: Set<Int> = lock.withLock {
            var values = Set<Int>()
            for record in records.values where record.written && record.scope == scope
                && time - record.lastUseTime <= Double(configuration.ttlSeconds) {
                for frontier in record.frontiers.keys where frontier <= maximumFrontier && frontier <= tokens.count {
                    values.insert(frontier)
                }
            }
            return values
        }
        guard !candidates.isEmpty else { return [] }
        let computed = QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: candidates)
        return lock.withLock {
            computed.filter { frontier, key in
                guard let name = byKey[key], let record = records[name] else { return false }
                return record.written && record.frontiers[frontier] == key && time - record.lastUseTime <= Double(configuration.ttlSeconds)
            }.keys.sorted(by: >)
        }
    }

    /// The state at `frontier`, read from its record; nil when this rank
    /// cannot restore it (no record, or one that cannot be read or
    /// authenticated, which is deleted). Only a failed `check` (the request's
    /// own deadline, cancellation or a peer fault) throws; the record is kept.
    func restore(scope: String, tokens: [Int], frontier: Int, check: () throws -> Void) throws -> QwenStagePrefixState? {
        guard let key = QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: [frontier])[frontier] else {
            return nil
        }
        let found: String? = lock.withLock {
            guard let name = byKey[key], let record = records[name], record.written, record.frontiers[frontier] == key else {
                return nil
            }
            pinned.insert(name)
            return name
        }
        guard let name = found else {
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-failed frontier=\(frontier) error=no_record")
            return nil
        }
        defer { _ = lock.withLock { pinned.remove(name) } }
        let url = directory.appendingPathComponent(name)
        var checkFailed = false
        func guarded() throws { do { try check() } catch { checkFailed = true; throw error } }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let opened = try QwenStagePrefixDiskIO.open(url: url, keys: keys)
            guard opened.header.scope == scope, opened.header.frontiers.contains(where: { $0.tokens == frontier && $0.key == key }) else {
                throw ProbeError("Prefix SSD record does not belong to this prompt")
            }
            if fault?.restoreFails == true {
                throw QwenStagePrefixDiskInjectedFault()
            }
            let state = try QwenStagePrefixDiskIO.restore(url: url, opened: opened, frontier: frontier,
                stallMilliseconds: fault?.restoreStallMilliseconds, check: guarded)
            let bytes = state.attention.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
                + state.recurrent.values.reduce(0) { $0 + $1.conv.nbytes + $1.ssm.nbytes }
                + (state.speculativeHistory.map { $0.hidden.nbytes + $0.tokens.nbytes + $0.last.nbytes } ?? 0)
            touch(name: name)
            lock.withLock { statistics.restores += 1; statistics.restoredBytes += bytes }
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore frontier=\(frontier) bytes=\(bytes)"
                + " ms=\((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
            return state
        } catch {
            lock.withLock { statistics.failedRestores += 1 }
            if !checkFailed && !(error is QwenStagePrefixDiskInjectedFault) {
                remove(name: name, reason: "unreadable")
            }
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-failed frontier=\(frontier) check=\(checkFailed)"
                + " error=\(qwenPrefixLogWord(error))")
            if checkFailed { throw error }
            return nil
        }
    }

    /// Deletes the record holding this frontier: its state did not fit this
    /// rank's stage when adopted, so it must not be offered again.
    func forget(scope: String, tokens: [Int], frontier: Int) {
        guard let key = QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: [frontier])[frontier],
              let name = lock.withLock({ byKey[key] }) else { return }
        remove(name: name, reason: "not_adoptable")
    }

    /// A resident hit keeps the record that holds the same frontier recent too,
    /// so both tiers age alike on both ranks.
    func touch(scope: String, tokens: [Int], frontier: Int) {
        guard let key = QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: [frontier])[frontier],
              let name = lock.withLock({ byKey[key] }) else { return }
        touch(name: name)
    }

    private func touch(name: String) {
        let time = now()
        let exists: Bool = lock.withLock {
            guard var record = records[name] else { return false }
            clock += 1; record.lastUse = clock; record.lastUseTime = time; records[name] = record
            return record.written
        }
        guard exists else { return }
        let path = directory.appendingPathComponent(name).path
        group.enter()
        queue.async { [group] in
            defer { group.leave() }
            Self.setModificationTime(path, time)
        }
    }

    // MARK: persist

    /// Persists one cleanly retired request's captured frontiers as a record
    /// (the deepest frontier's attention copy and the recurrent state at the
    /// deepest frontier and at each frontier on the disk grid). Prepares the
    /// bytes here, on the serving thread, and writes behind. An existing
    /// record of the same prompt is only touched.
    func persist(scope: String, tokens: [Int], states: [QwenStagePrefixState], blockTokens: Int) {
        guard let deepest = states.max(by: { $0.committedTokens < $1.committedTokens }),
              deepest.committedTokens >= configuration.minimumTokens, blockTokens > 0,
              deepest.committedTokens <= tokens.count else { return }
        let committed = deepest.committedTokens
        // The disk grid: a multiple of the block, doubled until a record keeps
        // at most `maximumGridFrontiers` besides N-1 (a long prompt's record
        // stays bounded: each frontier is a whole recurrent state).
        var stride = max(1, (configuration.strideTokens + blockTokens - 1) / blockTokens) * blockTokens
        while (committed - 1) / stride > Self.maximumGridFrontiers { stride *= 2 }
        let chosen = states.filter { $0.committedTokens == committed || ($0.committedTokens % stride == 0 && $0.committedTokens > 0) }
        let frontierKeys = QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: Set(chosen.map(\.committedTokens)))
        guard let recordKey = frontierKeys[committed] else { return }
        let name = keys.fileName(recordKey: recordKey)
        let estimate = chosen.reduce(0) { total, state in
            total + state.recurrent.values.reduce(0) { $0 + $1.conv.nbytes + $1.ssm.nbytes }
                + (state.speculativeHistory.map { $0.hidden.nbytes + $0.tokens.nbytes + $0.last.nbytes } ?? 0)
        } + deepest.attention.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
        enum Decision { case touch, drop(String), write }
        let decision: Decision = lock.withLock {
            if records[name] != nil { return .touch }
            if cancelled { return .drop("closing") }
            if queuedJobs >= configuration.maximumQueuedJobs { return .drop("queue_full") }
            if queuedBytes + estimate > configuration.maximumQueuedBytes { return .drop("queue_bytes") }
            return .write
        }
        switch decision {
        case .touch: touch(name: name); return
        case .drop(let reason):
            lock.withLock { statistics.droppedPersists += 1 }
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=persist-dropped reason=\(reason) prompt=\(committed)")
            return
        case .write: break
        }
        let job: QwenStagePrefixDiskJob
        do {
            job = try QwenStagePrefixDiskJob.prepare(scope: scope, recordKey: recordKey, fileName: name, deepest: deepest,
                frontiers: chosen.map { ($0, frontierKeys[$0.committedTokens]!) }, blockTokens: blockTokens)
        } catch {
            lock.withLock { statistics.droppedPersists += 1 }
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=persist-dropped reason=unstorable")
            return
        }
        let accepted: Bool = lock.withLock {
            guard records[name] == nil, !cancelled else { return false }
            clock += 1
            records[name] = Record(name: name, scope: scope, recordKey: recordKey, committedTokens: committed,
                frontiers: Dictionary(uniqueKeysWithValues: job.header.frontiers.map { ($0.tokens, $0.key) }),
                bytes: 0, lastUse: clock, lastUseTime: now(), written: false)
            queuedJobs += 1; queuedBytes += job.hostBytes
            return true
        }
        guard accepted else { return }
        group.enter()
        queue.async { [self] in
            defer { group.leave() }
            write(job)
        }
    }

    private func write(_ job: QwenStagePrefixDiskJob) {
        defer { lock.withLock { queuedJobs -= 1; queuedBytes -= job.hostBytes } }
        let name = job.fileName, expected = job.header.dataBytes + 64 * 1024
        let start = DispatchTime.now().uptimeNanoseconds
        func abandon(_ reason: String) {
            lock.withLock {
                if records[name]?.written == false { records.removeValue(forKey: name) }
                statistics.droppedPersists += 1
            }
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=persist-dropped reason=\(reason) prompt=\(job.header.committedTokens)")
        }
        if lock.withLock({ cancelled }) { abandon("closing"); return }
        removeExpired()
        let time = now()
        loadWriteWindow(time)
        if lock.withLock({ writeWindowBytes }) > configuration.maximumWriteBytesPerDay - expected {
            abandon("daily_write_cap"); return
        }
        if let free = Self.freeBytes(directory), free < configuration.minimumFreeBytes + expected {
            abandon("low_disk"); return
        }
        let temporary = directory.appendingPathComponent(".\(name).\(getpid()).tmp")
        unlink(temporary.path)
        do {
            let bytes = try QwenStagePrefixDiskIO.write(job: job, keys: keys, to: temporary,
                cancelled: { [self] in lock.withLock { cancelled } })
            let final = directory.appendingPathComponent(name)
            guard rename(temporary.path, final.path) == 0 else { throw ProbeError("Prefix record rename failed (errno \(errno))") }
            let written = now()
            Self.setModificationTime(final.path, written)
            lock.withLock {
                if var record = records[name] {
                    record.written = true; record.bytes = bytes; record.lastUseTime = written; records[name] = record
                    for key in record.frontiers.values { byKey[key] = name }
                }
                statistics.persisted += 1; statistics.persistedBytes += bytes
                writeWindowBytes += bytes
                lastCompletedWrite = written
            }
            saveWriteWindow()
            evictOverLimits(protecting: name)
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=persist prompt=\(job.header.committedTokens)"
                + " frontiers=\(job.header.frontiers.map { String($0.tokens) }.joined(separator: "_"))"
                + " bytes=\(bytes) ms=\((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) records=\(recordCount)")
        } catch {
            unlink(temporary.path)
            abandon("write_failed")
        }
    }

    // MARK: lifecycle

    /// Waits for writes already queued (bounded); true when none is left.
    @discardableResult
    func drain(timeoutSeconds: Double) -> Bool {
        group.wait(timeout: .now() + timeoutSeconds) == .success
    }

    /// Before the model is released: finish what was queued (bounded), then
    /// refuse new work. As oMLX's engine teardown (`a58afee1`): the bound is
    /// extended ONCE, by itself, when the writer completed a record within the
    /// bound (it is making progress; a queued record is what a restarted pair
    /// restores), never when it is stuck. A write still running when the
    /// final bound passes stops at its next unit and leaves only a temporary
    /// file, deleted at next load.
    func close(timeoutSeconds: Double = 20) {
        var drained = drain(timeoutSeconds: timeoutSeconds)
        var extended = false
        if Self.teardownExtends(drained: drained, lastCompletedWrite: lock.withLock { lastCompletedWrite },
                                closeBegan: now() - timeoutSeconds, boundSeconds: timeoutSeconds) {
            extended = true
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=close-extended bound_s=\(Int(timeoutSeconds)) queued=\(lock.withLock { queuedJobs })")
            drained = drain(timeoutSeconds: timeoutSeconds)
        }
        lock.withLock { cancelled = true; statistics.closeExtended = extended; statistics.closeDrained = drained }
        if !drained { _ = drain(timeoutSeconds: 5) }
        // This rank no longer uses the plan directory.
        lock.withLock { if inUse >= 0 { Darwin.close(inUse); inUse = -1 } }
        log("darkbloom-prefix-ssd-v1 rank=\(rank) event=close drained=\(drained) extended=\(extended) records=\(recordCount)")
    }

    /// The teardown rule, pure: one extension of `boundSeconds` when the
    /// first bound passed without draining and a record completed since the
    /// close began (progress within the bound); none when nothing completed
    /// (a stuck disk must not hold the model release).
    static func teardownExtends(drained: Bool, lastCompletedWrite: TimeInterval?, closeBegan: TimeInterval,
                                boundSeconds: Double) -> Bool {
        guard !drained, boundSeconds > 0, let last = lastCompletedWrite else { return false }
        return last >= closeBegan
    }

    /// Deletes every record of this rank (diagnosis and tests).
    func sweep() {
        drain(timeoutSeconds: 20)
        let names = lock.withLock { Array(records.keys) }
        for name in names { remove(name: name, reason: "sweep") }
    }

    // MARK: eviction

    private func evictOverLimits(protecting: String?) {
        while true {
            let victim: String? = lock.withLock {
                let written = records.values.filter { $0.written }
                let bytes = written.reduce(0) { $0 + $1.bytes }
                guard written.count > configuration.recordLimit || bytes > configuration.byteBudget else { return nil }
                return written.filter { $0.name != protecting && !pinned.contains($0.name) }
                    .min(by: { ($0.lastUse, $0.name) < ($1.lastUse, $1.name) })?.name
            }
            guard let victim else { return }
            remove(name: victim, reason: "evicted")
            lock.withLock { statistics.evictions += 1 }
        }
    }

    private func removeExpired() {
        let time = now()
        let expired = lock.withLock {
            records.values.filter { $0.written && !pinned.contains($0.name)
                && time - $0.lastUseTime > Double(configuration.ttlSeconds) }.map(\.name)
        }
        for name in expired { remove(name: name, reason: "expired"); lock.withLock { statistics.expirations += 1 } }
    }

    private func remove(name: String, reason: String) {
        lock.withLock {
            guard let record = records.removeValue(forKey: name) else { return }
            for key in record.frontiers.values where byKey[key] == name {
                // Another record may hold the same frontier; the most recent wins.
                if let other = records.values.filter({ $0.written && $0.frontiers.values.contains(key) })
                    .max(by: { $0.lastUse < $1.lastUse }) {
                    byKey[key] = other.name
                } else {
                    byKey.removeValue(forKey: key)
                }
            }
        }
        unlink(directory.appendingPathComponent(name).path)
        _ = reason
    }

    // MARK: index

    private func loadIndex() {
        let fileManager = FileManager.default
        let checkURL = directory.appendingPathComponent("key-check")
        let check = (try? String(contentsOf: checkURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        if check != keys.keyCheck {
            // Another key wrote these records: none of them can be read.
            for name in names { unlink(directory.appendingPathComponent(name).path); statistics.sweptFiles += 1 }
            let temporary = directory.appendingPathComponent(".key-check.\(getpid()).tmp")
            unlink(temporary.path)
            if (try? Data((keys.keyCheck + "\n").utf8).write(to: temporary, options: .withoutOverwriting)) != nil {
                rename(temporary.path, checkURL.path)
            }
            return
        }
        let time = now()
        var loaded: [(Record, TimeInterval)] = []
        for name in names where name != "key-check" && name != "write-window" {
            let url = directory.appendingPathComponent(name)
            guard name.hasSuffix(".dbpx"), !name.hasPrefix("."),
                  let opened = try? QwenStagePrefixDiskIO.open(url: url, keys: keys),
                  keys.fileName(recordKey: opened.header.recordKey) == name else {
                unlink(url.path); statistics.sweptFiles += 1; continue
            }
            let modified = Self.modificationTime(url.path) ?? 0
            guard time - modified <= Double(configuration.ttlSeconds) else {
                unlink(url.path); statistics.expirations += 1; continue
            }
            loaded.append((Record(name: name, scope: opened.header.scope, recordKey: opened.header.recordKey,
                committedTokens: opened.header.committedTokens,
                frontiers: Dictionary(opened.header.frontiers.map { ($0.tokens, $0.key) }, uniquingKeysWith: { a, _ in a }),
                bytes: opened.fileBytes, lastUse: 0, lastUseTime: modified, written: true), modified))
        }
        // Recency from the files' modification times, oldest first.
        for (record, _) in loaded.sorted(by: { ($0.1, $0.0.name) < ($1.1, $1.0.name) }) {
            clock += 1
            var value = record; value.lastUse = clock
            records[value.name] = value
            for key in value.frontiers.values { byKey[key] = value.name }
        }
    }

    private var writeWindowURL: URL { directory.appendingPathComponent("write-window") }

    private func loadWriteWindow(_ time: TimeInterval) {
        lock.withLock {
            if writeWindowStart == 0,
               let text = try? String(contentsOf: writeWindowURL, encoding: .utf8) {
                let parts = text.split(separator: " ")
                if parts.count == 2, let start = Double(parts[0]), let bytes = Int(parts[1]) {
                    writeWindowStart = start; writeWindowBytes = bytes
                }
            }
            if writeWindowStart == 0 || time - writeWindowStart >= 86_400 || time < writeWindowStart {
                writeWindowStart = time; writeWindowBytes = 0
            }
        }
    }

    private func saveWriteWindow() {
        let text = lock.withLock { "\(writeWindowStart) \(writeWindowBytes)\n" }
        let temporary = directory.appendingPathComponent(".write-window.\(getpid()).tmp")
        unlink(temporary.path)
        if (try? Data(text.utf8).write(to: temporary, options: .withoutOverwriting)) != nil {
            rename(temporary.path, writeWindowURL.path)
        }
    }

    // MARK: files

    static func makePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw ProbeError("Prefix SSD directory is not a directory this user owns")
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Deletes every plan directory under `root` except `keeping` (all when
    /// nil) and except one a live rank holds (its `in-use` lock). Only names
    /// this tier creates are touched.
    @discardableResult
    static func sweepPlans(root: URL, keeping: String?) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var removed = 0
        for name in names where isPlanDirectoryName(name) && name != keeping {
            let plan = root.appendingPathComponent(name, isDirectory: true)
            let lock = Darwin.open(plan.appendingPathComponent("in-use").path, O_RDONLY | O_NOFOLLOW)
            if lock >= 0 {
                defer { Darwin.close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }
            }
            if (try? FileManager.default.removeItem(at: plan)) != nil { removed += 1 }
        }
        return removed
    }

    deinit { if inUse >= 0 { Darwin.close(inUse) } }

    static func modificationTime(_ path: String) -> TimeInterval? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    }

    static func setModificationTime(_ path: String, _ time: TimeInterval) {
        var times = [timeval(tv_sec: Int(time), tv_usec: Int32((time - floor(time)) * 1e6)),
                     timeval(tv_sec: Int(time), tv_usec: Int32((time - floor(time)) * 1e6))]
        _ = utimes(path, &times)
    }

    static func freeBytes(_ url: URL) -> Int? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return Int(info.f_bavail) * Int(info.f_bsize)
    }
}

/// Log text for the launcher's runtime lines: lowercase letters, digits and '_'.
func qwenPrefixLogWord(_ value: Any) -> String {
    String(String(describing: value).lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "_" }.prefix(120))
}

/// A qualification fault, not a bad record: the record is kept.
struct QwenStagePrefixDiskInjectedFault: Error, CustomStringConvertible {
    var description: String { "qualification fault: prefix SSD restore fails" }
}
