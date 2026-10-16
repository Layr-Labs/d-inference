import Foundation
import MLX

/// One stage's committed request state at an exact prompt frontier, kept on
/// the rank that computed it. Arrays are keyed by the model's global layer
/// index, as a hand-off's are. Attention arrays hold exactly
/// `committedTokens` positions; recurrent arrays are the confirmed state after
/// exactly that many tokens.
struct QwenStagePrefixState {
    let committedTokens: Int
    let attention: [Int: (keys: MLXArray, values: MLXArray)]
    let recurrent: [Int: (conv: MLXArray, ssm: MLXArray)]
    /// On the decoding rank of a speculative pair: the head's trusted history
    /// at this frontier, so that a request restoring it drafts from the whole
    /// prompt as a cold request does, not only from its computed suffix.
    var speculativeHistory: QwenMTPPrefixHistory? = nil

    var adopted: QwenLayerStageAdoptedState {
        .init(committedTokens: committedTokens, attention: attention, recurrent: recurrent)
    }

    /// Bytes this frontier holds alone: its recurrent arrays, compact
    /// (`QwenLayerStageSession.capturePrefix`). Its attention rows and
    /// speculative history are views of its prompt's one copy, counted once
    /// per prompt (`QwenStagePrefixCache.insert(sharedBytes:)`).
    var ownBytes: Int { recurrent.values.reduce(0) { $0 + $1.conv.nbytes + $1.ssm.nbytes } }

    /// The storage this state views besides its own: its attention copy and
    /// speculative history. A state read from the SSD tier owns these alone
    /// (nothing else views them), so a promotion into the resident tier
    /// charges them as the prompt's shared bytes (the F1 budget counts every
    /// resident byte once, captured or restored).
    var sharedBytes: Int {
        attention.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
            + (speculativeHistory.map { $0.hidden.nbytes + $0.tokens.nbytes + $0.last.nbytes } ?? 0)
    }
}

/// What one capture of a loaded stage costs, measured from its first
/// capture (the same for every request of that stage): a prompt's capture
/// is one attention copy and one speculative history at its deepest
/// frontier, shared by its frontiers, plus one recurrent state a frontier.
struct QwenStagePrefixCaptureCost: Equatable {
    /// Keys and values of every attention layer of the stage, a prompt token.
    let attentionBytesPerToken: Int
    /// Compact convolution and SSM state of every recurrent layer, a frontier.
    let recurrentBytesPerFrontier: Int
    /// The decoding rank's speculative history, a prompt token; 0 elsewhere.
    let historyBytesPerToken: Int

    /// The shared copy at `deepest` plus `frontiers` recurrent states.
    func bytes(deepest: Int, frontiers: Int) -> Int {
        guard deepest > 0, frontiers > 0 else { return 0 }
        let shared = (attentionBytesPerToken.multipliedReportingOverflow(by: deepest),
                      historyBytesPerToken.multipliedReportingOverflow(by: deepest))
        let own = recurrentBytesPerFrontier.multipliedReportingOverflow(by: frontiers)
        guard !shared.0.overflow, !shared.1.overflow, !own.overflow else { return Int.max }
        let total = shared.0.partialValue.addingReportingOverflow(shared.1.partialValue)
        let all = total.partialValue.addingReportingOverflow(own.partialValue)
        return total.overflow || all.overflow ? Int.max : all.partialValue
    }

    /// The frontiers of `planned` (ascending; the last is the deepest, the
    /// split frontier) that a capture within `limit` keeps: the deepest,
    /// then the deepest grid frontiers that still fit, at most `maximum` in
    /// all. Empty when even the deepest alone does not fit.
    func kept(_ planned: [Int], limit: Int, maximum: Int) -> Set<Int> {
        guard let deepest = planned.last, maximum > 0 else { return [] }
        let base = bytes(deepest: deepest, frontiers: 1)
        guard base <= limit else { return [] }
        let room = limit - base
        let more = recurrentBytesPerFrontier > 0 ? room / recurrentBytesPerFrontier : planned.count
        let count = min(planned.count - 1, maximum - 1, more)
        return Set(planned.dropLast().suffix(max(0, count))).union([deepest])
    }
}

/// Rank-local resident prompt-prefix cache of one loaded stage.
///
/// Both ranks key an entry by the same string: the request scope both ranks
/// agreed (plan, artifact, storage, arithmetic, profile, chunk size) and the
/// prompt tokens before the frontier. Each rank stores only its own stage's
/// state under that key. Nothing here decides reuse: the two ranks exchange
/// the frontiers they hold and reuse only one both hold
/// (`QwenStagePrefixAgreement`).
///
/// Retention is by budget, as the single-Mac prefix cache's: a byte budget
/// (`budgetBytes`, derived by the runtime from the rank's admissible memory
/// beside its serving context) and a prompt count (`promptLimit`, as the SSD
/// tier's record limit), with a frontier count only as a safety bound. Under
/// pressure the grid frontiers of prompts other than the most recently used
/// go first (least recently used first), then whole prompts: the resident
/// tier keeps as many prompts as the budget holds (every exact repeat hits)
/// and the SSD tier keeps their grid (finding F4: a frontier-count limit of
/// 32 held only the last two 8K prompts, so 4 rotating documents missed). Bytes are counted as held: each frontier's
/// compact recurrent state, plus its prompt's one attention copy and history
/// once, freed with the prompt's last entry. Entries are inserted only after
/// a request retired cleanly on both ranks; a request's own capture is
/// charged in its reservation (`captureLimit`) and kept within it by the
/// stage session. Neither ever fails a request for memory: kept entries give
/// way first (`yieldingMemory`), then the request's own capture
/// (`withdrawCapture`). A sweep drops every entry; the runtime sweeps before
/// it releases its model and after a failed request.
public final class QwenStagePrefixCache: @unchecked Sendable {
    /// One entry is one frontier of one prompt: its recurrent state (about
    /// 110 MB on the 27B's larger stage, compact) and a view of its prompt's
    /// attention copy, which is shared by every frontier of that prompt.
    public static let defaultEntryLimit = 1024
    /// Prompts kept at most (the SSD tier's record limit); bytes bound first.
    public static let defaultPromptLimit = 64
    /// Frontiers one request captures at most (its split frontier and grid).
    public static let defaultFrontiersPerPrompt = 32
    /// The budget never exceeds this: a thirty-second of this Mac's memory
    /// (8 GiB on 256 GB; `QwenStagePrefixDiskPolicy.residentCeilingBytes`).
    public static let maximumBudgetBytes = QwenStagePrefixDiskPolicy.residentCeilingBytes(
        physicalBytes: ProcessInfo.processInfo.physicalMemory)
    /// Grid frontiers kept besides `promptCount - 1`: multiples of this many
    /// tokens (rounded up to a multiple of the request's chunk size). Keeping
    /// one costs its compact recurrent state (about 110 MB on the 27B's
    /// larger stage), so the grid is coarser than the chunk size.
    public static let defaultStrideTokens = 512
    /// Most frontiers one rank offers its peer for one request.
    static let maximumOffered = 32

    /// The diagnosis switch: off means this rank offers nothing and asks for
    /// no split, so the pair runs exactly as it did before the cache existed.
    public let enabled: Bool
    public let entryLimit: Int
    public let promptLimit: Int
    public let frontiersPerPrompt: Int
    public let strideTokens: Int

    private struct Entry {
        let key: String
        let scope: String
        let state: QwenStagePrefixState
        var lastUse: UInt64
        let ownBytes: Int
        let prompt: UInt64
    }
    /// One inserted prompt's shared storage and how many entries view it.
    private struct Prompt { let sharedBytes: Int; var entries: Int; let deepest: Int }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var prompts: [UInt64: Prompt] = [:]
    private var nextPrompt: UInt64 = 0
    private var clock: UInt64 = 0
    private var held = 0
    private var budget: Int
    private var measured: QwenStagePrefixCaptureCost?
    private(set) var evictions = 0

    public init(enabled: Bool = true, entryLimit: Int = QwenStagePrefixCache.defaultEntryLimit,
                strideTokens: Int = QwenStagePrefixCache.defaultStrideTokens,
                budgetBytes: Int = QwenStagePrefixCache.maximumBudgetBytes,
                promptLimit: Int = QwenStagePrefixCache.defaultPromptLimit, frontiersPerPrompt: Int? = nil) {
        self.enabled = enabled
        self.entryLimit = max(1, min(entryLimit, 1024))
        self.promptLimit = max(1, min(promptLimit, 1024))
        self.frontiersPerPrompt = max(1, min(frontiersPerPrompt ?? Self.defaultFrontiersPerPrompt, self.entryLimit))
        self.strideTokens = max(1, strideTokens)
        budget = max(0, budgetBytes)
    }

    /// Bytes the entries hold now (shared copies once).
    public var bytesInUse: Int { lock.withLock { held } }
    /// Most bytes the entries may hold.
    public var budgetBytes: Int { lock.withLock { budget } }
    /// The measured capture cost of this stage, once a capture was taken.
    var captureCost: QwenStagePrefixCaptureCost? { lock.withLock { measured } }

    /// The budget for `roomBytes` of admissible memory left beside the
    /// serving context's charge: half of it, at most `maximumBudgetBytes`,
    /// rounded down to 256 MiB so the idle refresh does not move it with
    /// every small drift. The serving context is never reduced for the
    /// cache; the other half stays for the desktop's own drift.
    public static func budget(roomBytes: Int) -> Int {
        max(0, min(maximumBudgetBytes, roomBytes / 2) / budgetGranuleBytes * budgetGranuleBytes)
    }
    static let budgetGranuleBytes = 256 << 20
    /// The room a memory-bound serving context leaves for the cache: one granule of budget (half the room).
    static let contextReserveBytes = 2 * budgetGranuleBytes

    /// Sets the budget and evicts least recently used entries beyond it.
    public func setBudget(_ bytes: Int) {
        lock.withLock { budget = max(0, bytes); evictLocked(reserving: 0) }
    }

    /// Records a measured capture cost (the first one stands; it is a
    /// property of the loaded stage).
    func record(_ cost: QwenStagePrefixCaptureCost) { lock.withLock { if measured == nil { measured = cost } } }

    /// Most bytes a request may capture, charged in its reservation: its
    /// capture plan after `heldFrontier` (the deepest prefix of its prompt
    /// this rank holds, which it reuses), at the measured cost, within the
    /// budget; the budget itself until a capture of this stage was measured.
    /// A repeat of the whole prompt (its split frontier held) captures
    /// nothing. Zero when off.
    ///
    /// If the peer holds less, the pair reuses less and the session plans
    /// more frontiers than charged; it still keeps within this limit (the
    /// split frontier and fewer grid frontiers, or nothing on a charged
    /// repeat, whose prompt this rank already holds).
    func captureLimit(promptCount: Int, chunkSize: Int, heldFrontier: Int = 0) -> Int {
        guard enabled, promptCount >= 2, heldFrontier < promptCount - 1 else { return 0 }
        return lock.withLock {
            guard let measured else { return budget }
            let step = stride(chunkSize: chunkSize)
            // Grid frontiers after the held prefix, below the split frontier.
            let grid = (promptCount - 2) / step - max(0, heldFrontier) / step
            let frontiers = min(frontiersPerPrompt, grid + 1)
            return min(budget, measured.bytes(deepest: promptCount - 1, frontiers: frontiers))
        }
    }

    /// The capture limit of a request for `tokens` under `scope`, after the
    /// deepest frontier this rank holds for it (recency untouched).
    func captureLimit(scope: String, tokens: [Int], chunkSize: Int) -> Int {
        guard enabled, tokens.count >= 2 else { return 0 }
        let held = deepestFrontier(scope: scope, tokens: tokens, maximumFrontier: tokens.count - 1)
        return captureLimit(promptCount: tokens.count, chunkSize: chunkSize, heldFrontier: held)
    }

    /// The deepest frontier this rank holds for `tokens` under `scope`, at
    /// most `maximumFrontier` (0: none), as `frontiers(...).first`. Every held
    /// frontier's key comes from one pass over the prompt
    /// (`QwenStagePrefixKeys`, finding F10: one full hash per held frontier
    /// was quadratic in the prompt). Does not touch recency.
    func deepestFrontier(scope: String, tokens: [Int], maximumFrontier: Int) -> Int {
        guard enabled else { return 0 }
        let limit = min(maximumFrontier, tokens.count)
        var keys: [Int: Set<String>] = [:]
        lock.withLock {
            for entry in entries.values where entry.scope == scope
                && entry.state.committedTokens > 0 && entry.state.committedTokens <= limit {
                keys[entry.state.committedTokens, default: []].insert(entry.key)
            }
        }
        let computed = prefixKeys(scope: scope, tokens: tokens, frontiers: Set(keys.keys))
        return keys.keys.sorted(by: >).first { frontier in
            computed[frontier].map { keys[frontier]?.contains($0) == true } ?? false
        } ?? 0
    }

    /// Prompt tokens fed to prefix hashers by lookups, for tests and
    /// diagnostics: one pass hashes at most the deepest frontier asked for.
    var lookupHashedTokens: Int { lock.withLock { hashedTokens } }
    private var hashedTokens = 0

    /// The shared keys of `tokens` at `frontiers` in one pass (each equals
    /// `key(scope:tokens:)` of that prefix).
    private func prefixKeys(scope: String, tokens: [Int], frontiers: Set<Int>) -> [Int: String] {
        guard let deepest = frontiers.filter({ $0 > 0 && $0 <= tokens.count }).max() else { return [:] }
        lock.withLock { hashedTokens += deepest }
        return QwenStagePrefixKeys.keys(scope: scope, tokens: tokens, frontiers: frontiers)
    }

    /// The idle refresh: the budget follows `roomBytes`, the admissible room
    /// left beside the serving context now (`budget(roomBytes:)`), in both
    /// directions, so a load during a memory dip does not keep it small for as
    /// long as the model stays loaded. Entries beyond a lower budget go now.
    /// True when the budget changed.
    @discardableResult func refreshBudget(roomBytes: Int) -> Bool {
        let target = Self.budget(roomBytes: roomBytes)
        return lock.withLock {
            guard target != budget else { return false }
            budget = target; evictLocked(reserving: 0); return true
        }
    }

    /// The decoding rank's speculative history a prompt token, as the
    /// reservation charges it (`captureLimit`): the measured figure once a
    /// capture of this stage was measured, else `estimate`. The session keeps
    /// its capture by the same figure; a larger estimate there would leave a
    /// charge with one frontier (a short prompt, or a hit in its prompt's last
    /// stride) too small for even its split frontier, so it captured nothing.
    func historyBytesPerToken(estimate: Int) -> Int { lock.withLock { measured?.historyBytesPerToken ?? estimate } }

    /// The capture limit the runtime charged in the current reservation,
    /// handed to that request's stage session once (one request at a time a
    /// rank). Nil when no reservation set one (unbounded: references, tests).
    private var admittedCapture: Int?
    /// A new reservation starts with its capture in place.
    func admitCapture(_ bytes: Int?) {
        lock.withLock { admittedCapture = bytes; captureHook = nil; captureWithdrawn = false }
    }
    func takeAdmittedCapture() -> Int? { lock.withLock { defer { admittedCapture = nil }; return admittedCapture } }

    /// The running request's capture, as its stage session holds it: `withdraw`
    /// releases what it captured and stops any further capture (set by the
    /// driver once the session's capture plan is set, cleared at its end).
    private var captureHook: (() -> Void)?
    private var captureWithdrawn = false
    private(set) var captureWithdrawals = 0

    /// Registers the running request's capture. If the running check already
    /// withdrew it, `withdraw` runs at once.
    func beginCapture(withdraw: @escaping () -> Void) {
        let already = lock.withLock { () -> Bool in
            if captureWithdrawn { return true }
            captureHook = withdraw; return false
        }
        if already { withdraw() }
    }

    func endCapture() { lock.withLock { captureHook = nil } }

    /// Whether the running request's capture was withdrawn.
    var captureWasWithdrawn: Bool { lock.withLock { captureWithdrawn } }

    /// The running check's step before it would fail its request for memory:
    /// the request's own capture is optional, so it is withdrawn (released,
    /// nothing more captured, nothing stored for this request) and the request
    /// goes on charged without it. Applies before the capture starts too: a
    /// capture not yet handed to the session is handed over as zero.
    func withdrawCapture() {
        let hook = lock.withLock { () -> (() -> Void)? in
            if admittedCapture != nil { admittedCapture = 0 }
            captureWithdrawn = true; captureWithdrawals += 1
            defer { captureHook = nil }
            return captureHook
        }
        hook?()
    }

    /// Before a request captures up to `bytes`: drops grid frontiers (least
    /// recently used first, other prompts' before the newest's) until the
    /// entries and that capture fit the budget together. It never drops a
    /// prompt's deepest frontier, what an exact repeat needs (finding F3: on
    /// the 27B's decoding rank a long prompt's capture plan of up to 32
    /// frontiers evicted every other prompt's deepest frontier first, so
    /// repeats of a few long documents never hit although their deepest
    /// frontiers fit the budget). Once the request retired, `insert` keeps
    /// the budget: the capture's own grid goes before another prompt's
    /// deepest frontier. Memory stays bounded meanwhile: the capture is
    /// charged in the request's reservation, and a live refusal still evicts
    /// any entry (`yieldingMemory`).
    func makeRoom(forCapture bytes: Int) {
        lock.withLock { evictLocked(reserving: max(0, bytes), gridOnly: true) }
    }

    private func remove(_ entry: Entry) {
        entries.removeValue(forKey: entry.key)
        held -= entry.ownBytes
        if var prompt = prompts[entry.prompt] {
            prompt.entries -= 1
            if prompt.entries <= 0 { prompts.removeValue(forKey: entry.prompt); held -= prompt.sharedBytes }
            else { prompts[entry.prompt] = prompt }
        }
    }

    private func evictLocked(reserving: Int, gridOnly: Bool = false) {
        // Over the prompt count: the least recently used prompt goes whole
        // (thinning other prompts' grids would not lower the count).
        while prompts.count > promptLimit, let prompt = leastRecentlyUsedPromptLocked() {
            for entry in entries.values where entry.prompt == prompt { remove(entry); evictions += 1 }
        }
        while entries.count > entryLimit || (held > 0 && held > budget - min(budget, reserving)),
              let victim = victimLocked(gridOnly: gridOnly) {
            remove(victim); evictions += 1
        }
    }

    /// The prompt whose most recent use is the oldest.
    private func leastRecentlyUsedPromptLocked() -> UInt64? {
        var latest: [UInt64: UInt64] = [:]
        for entry in entries.values { latest[entry.prompt] = max(latest[entry.prompt] ?? 0, entry.lastUse) }
        return latest.min(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key
    }

    /// The next entry to evict: the least recently used grid frontier of a
    /// prompt other than the most recently used one; then the most recently
    /// used prompt's own grid (its shallowest first); only when no grid
    /// frontier is left, the least recently used entry (a whole prompt's
    /// deepest frontier), and never one with `gridOnly`. A prompt's deepest
    /// frontier (what an exact repeat needs) outlives every grid frontier,
    /// the newest prompt's included (finding F3).
    private func victimLocked(gridOnly: Bool = false) -> Entry? {
        guard let newest = entries.values.max(by: { $0.lastUse < $1.lastUse }) else { return nil }
        func grid(_ entry: Entry) -> Bool { entry.state.committedTokens < (prompts[entry.prompt]?.deepest ?? 0) }
        let byRecency: (Entry, Entry) -> Bool = { ($0.lastUse, $0.state.committedTokens) < ($1.lastUse, $1.state.committedTokens) }
        if let other = entries.values.filter({ $0.prompt != newest.prompt && grid($0) }).min(by: byRecency) { return other }
        if let own = entries.values.filter({ $0.prompt == newest.prompt && grid($0) }).min(by: byRecency) { return own }
        return gridOnly ? nil : entries.values.min(by: byRecency)
    }

    /// Prompts held now (for tests and diagnostics).
    public var promptCount: Int { lock.withLock { prompts.count } }

    /// From the worker's environment. `DARKBLOOM_CLUSTER_PREFIX_CACHE=off`
    /// turns it off for diagnosis; anything else (or nothing) leaves it on.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> QwenStagePrefixCache {
        let value = environment["DARKBLOOM_CLUSTER_PREFIX_CACHE"]?.lowercased()
        let off = value == "off" || value == "0" || value == "false" || value == "no"
        return QwenStagePrefixCache(enabled: !off)
    }

    public var count: Int { lock.withLock { entries.count } }

    /// This rank's SSD tier, attached once at load when it is configured
    /// (`QwenStagePrefixDiskTier`); nil when off. Never on with the cache off.
    public internal(set) var disk: QwenStagePrefixDiskTier?

    /// Frontiers on the grid of this request's chunk size.
    func stride(chunkSize: Int) -> Int {
        guard chunkSize > 0 else { return strideTokens }
        return max(1, (strideTokens + chunkSize - 1) / chunkSize) * chunkSize
    }

    static func key(scope: String, tokens: ArraySlice<Int>) -> String {
        sha256(Data(("darkbloom-cluster-prefix-v1|" + scope + "|" + qwenGenerationTokenHash(Array(tokens))).utf8))
    }

    /// Frontiers this rank holds for `tokens` under `scope`, at most
    /// `maximumFrontier`, deepest first. Does not touch recency.
    func frontiers(scope: String, tokens: [Int], maximumFrontier: Int) -> [Int] {
        guard enabled else { return [] }
        let held = lock.withLock { entries.values.filter { $0.scope == scope && $0.state.committedTokens <= maximumFrontier } }
            .filter { $0.state.committedTokens > 0 && $0.state.committedTokens <= tokens.count }
        // One pass over the prompt for every held frontier (finding F10).
        let keys = prefixKeys(scope: scope, tokens: tokens, frontiers: Set(held.map(\.state.committedTokens)))
        let found = held.filter { keys[$0.state.committedTokens] == $0.key }.map(\.state.committedTokens)
        return Array(Set(found).sorted(by: >).prefix(Self.maximumOffered))
    }

    /// The state at `frontier` for this prompt, marking it most recently used.
    func state(scope: String, tokens: [Int], frontier: Int) -> QwenStagePrefixState? {
        guard enabled, frontier > 0, frontier <= tokens.count else { return nil }
        let key = Self.key(scope: scope, tokens: tokens[0..<frontier])
        return lock.withLock {
            guard var entry = entries[key], entry.scope == scope, entry.state.committedTokens == frontier else { return nil }
            clock += 1; entry.lastUse = clock; entries[key] = entry
            return entry.state
        }
    }

    /// Inserts states of one cleanly retired request, then evicts the least
    /// recently used entries beyond the count limit or the budget.
    /// `sharedBytes` is the storage its states view together (the attention
    /// copy and speculative history at its deepest frontier), counted once
    /// and freed with the last of them.
    func insert(scope: String, tokens: [Int], states: [QwenStagePrefixState], sharedBytes: Int = 0) {
        guard enabled else { return }
        lock.withLock {
            let prompt = nextPrompt; nextPrompt += 1
            var added = 0, deepest = 0
            for state in states.sorted(by: { $0.committedTokens < $1.committedTokens }) {
                guard state.committedTokens > 0, state.committedTokens <= tokens.count else { continue }
                let key = Self.key(scope: scope, tokens: tokens[0..<state.committedTokens])
                if let old = entries[key] { remove(old) }
                clock += 1
                let own = state.ownBytes
                entries[key] = Entry(key: key, scope: scope, state: state, lastUse: clock, ownBytes: own, prompt: prompt)
                held += own; added += 1; deepest = max(deepest, state.committedTokens)
            }
            if added > 0 {
                prompts[prompt] = Prompt(sharedBytes: max(0, sharedBytes), entries: added, deepest: deepest)
                held += max(0, sharedBytes)
            }
            evictLocked(reserving: 0)
        }
    }

    /// Drops the least recently used entry; false when there is none.
    @discardableResult
    func evictLeastRecentlyUsed() -> Bool {
        lock.withLock {
            guard let oldest = victimLocked() else { return false }
            remove(oldest); evictions += 1
            return true
        }
    }

    /// Runs `check` (a live memory admission); while it refuses and entries
    /// remain, drops the least recently used entry, returns the freed buffers
    /// to the system and checks again. The cache never makes a request fail
    /// for memory: only a refusal with the cache empty is thrown.
    func yieldingMemory(_ check: () throws -> Void) throws {
        var evicted = 0
        var drained = false
        while true {
            do {
                try check()
                if evicted > 0 { log("darkbloom-prefix-v1 pressure-evicted=\(evicted) entries=\(count) admitted=true") }
                return
            } catch {
                // Records still queued for the SSD hold their arrays: finish
                // them first, then return their buffers, before evicting.
                if !drained, let disk {
                    drained = true
                    disk.drain(timeoutSeconds: 10)
                    Stream.gpu.synchronize()
                    Memory.clearCache()
                    continue
                }
                guard enabled, evictLeastRecentlyUsed() else {
                    if evicted > 0 { log("darkbloom-prefix-v1 pressure-evicted=\(evicted) entries=\(count) admitted=false") }
                    throw error
                }
                pressureEvictions += 1; evicted += 1
                // Buffers still referenced by finished GPU work are released
                // only after it completes; then return them to the system.
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
        }
    }
    private(set) var pressureEvictions = 0

    /// Drops every entry. The arrays are released when the last reference
    /// (an entry, or a session that is adopting one) goes away.
    public func sweep() {
        lock.withLock { entries.removeAll(keepingCapacity: false); prompts.removeAll(); held = 0 }
    }

    /// Committed frontiers currently held, for tests and diagnostics.
    var heldFrontiers: [Int] { lock.withLock { entries.values.map(\.state.committedTokens).sorted() } }
}
