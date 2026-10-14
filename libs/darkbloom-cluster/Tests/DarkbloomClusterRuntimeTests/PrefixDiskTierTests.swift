import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// The SSD tier of the rank-local prompt-prefix cache: keys, configuration,
// record round trips across a restart, the offer's tier bits, authentication,
// sweeps, eviction, expiry and the qualification faults. No collective, model
// or GPU kernels beyond creating and comparing small arrays.

private let heads = 2, headDim = 8, block = 8

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-ssd-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func configuration(_ root: URL, key: Data = Data(repeating: 7, count: 32),
                           _ change: (inout QwenStagePrefixDiskConfiguration) -> Void = { _ in }) -> QwenStagePrefixDiskConfiguration {
    var value = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: key))
    value.strideTokens = 16; value.minimumTokens = 1; value.minimumFreeBytes = 1
    change(&value)
    return value
}

/// One prompt's captured states on one rank: attention rows `[1, 2, D, 8]`
/// (bf16, values derived from `seed`) and recurrent state per frontier.
private func states(committed: Int, frontiers: [Int], seed: Int) -> [QwenStagePrefixState] {
    let count = heads * committed * headDim
    let base = (MLXArray(0..<count).asType(.float32) + Float(seed)).reshaped([1, heads, committed, headDim])
    let keys = (base * 0.5).asType(.bfloat16), values = (base * -0.25).asType(.bfloat16)
    eval(keys, values)
    return (frontiers + [committed]).map { f in
        let attention: [Int: (keys: MLXArray, values: MLXArray)] = f == committed
            ? [3: (keys: keys, values: values)]
            : [3: (keys: keys[0..., 0..., 0..<f, 0...], values: values[0..., 0..., 0..<f, 0...])]
        let conv = MLXArray((0..<12).map { Float($0 + f + seed) }).reshaped([1, 3, 4])
        let ssm = MLXArray((0..<16).map { Float($0 * f + seed) }).reshaped([1, 2, 2, 4])
        return QwenStagePrefixState(committedTokens: f, attention: attention, recurrent: [0: (conv: conv, ssm: ssm)])
    }
}


/// The decoding rank's speculative history at `frontier` (hidden `[1, f-1, 4]`
/// bf16, tokens `[1, f-1]` int32, last `[1, 1, 4]`), values from `seed`.
private func history(frontier: Int, seed: Int) -> QwenMTPPrefixHistory {
    let hidden = (MLXArray(0..<((frontier - 1) * 4)).asType(.float32) * 0.125 + Float(seed)).reshaped([1, frontier - 1, 4]).asType(.bfloat16)
    let tokens = MLXArray((1..<frontier).map { Int32($0 + seed) }).reshaped([1, frontier - 1])
    let last = (MLXArray(0..<4).asType(.float32) - Float(seed)).reshaped([1, 1, 4]).asType(.bfloat16)
    eval(hidden, tokens, last)
    return .init(frontier: frontier, hidden: hidden, tokens: tokens, last: last)
}

private func sameHistory(_ a: QwenMTPPrefixHistory?, _ b: QwenMTPPrefixHistory?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.frontier == b.frontier && equal(a.hidden, b.hidden) && equal(a.tokens, b.tokens) && equal(a.last, b.last)
}

private func equal(_ a: MLXArray, _ b: MLXArray) -> Bool {
    a.shape == b.shape && a.dtype == b.dtype && MLX.arrayEqual(a, b).item(Bool.self)
}

private func same(_ restored: QwenStagePrefixState, _ original: QwenStagePrefixState) -> Bool {
    guard restored.committedTokens == original.committedTokens,
          Set(restored.attention.keys) == Set(original.attention.keys),
          Set(restored.recurrent.keys) == Set(original.recurrent.keys) else { return false }
    for (layer, pair) in original.attention {
        guard let other = restored.attention[layer], equal(other.keys, pair.keys), equal(other.values, pair.values) else { return false }
    }
    for (layer, pair) in original.recurrent {
        guard let other = restored.recurrent[layer], equal(other.conv, pair.conv), equal(other.ssm, pair.ssm) else { return false }
    }
    return true
}

private func openTier(_ configuration: QwenStagePrefixDiskConfiguration, plan: String = "plan-a", rank: Int = 0,
                  fault: QwenStagePrefixDiskFault? = nil) throws -> QwenStagePrefixDiskTier {
    try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: plan, rank: rank, fault: fault))
}

@Suite("Prompt prefix SSD tier (rank-local, encrypted, swept)", .serialized)
struct PrefixDiskTierTests {
    @Test func incrementalKeysEqualTheSharedKeyAtEveryFrontier() {
        let tokens = (0..<300).map { ($0 * 7919) % 1000 }
        let keys = QwenStagePrefixKeys.keys(scope: "s|chunk=8", tokens: tokens, frontiers: [1, 8, 64, 299, 300, 301, 0])
        #expect(Set(keys.keys) == [1, 8, 64, 299, 300])
        for (frontier, key) in keys {
            #expect(key == QwenStagePrefixCache.key(scope: "s|chunk=8", tokens: tokens[0..<frontier]))
        }
    }

    @Test func configurationFailsClosedAndOnlyShortensTheTTL() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x0f, count: 32)
        #expect(QwenStagePrefixDiskConfiguration.fromEnvironment([:], key: key).mode == .off(sweepRoot: nil, reason: "no directory"))
        let noKey = QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path], key: nil)
        #expect(!noKey.enabled)
        if case .off(let sweep, _) = noKey.mode { #expect(sweep != nil) }
        let on = QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path,
            "DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS": "7200",
            "DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_RECORDS": "3", "DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB": "2"], key: key)
        #expect(on.enabled && on.ttlSeconds == 1800 && on.recordLimit == 3 && on.byteBudget == 2 * 1_073_741_824)
        let shorter = QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path,
            "DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS": "60"], key: key)
        #expect(shorter.ttlSeconds == 60)
        let off = QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path,
            "DARKBLOOM_CLUSTER_PREFIX_SSD": "off"], key: key)
        #expect(!off.enabled)
        #expect(!QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": "relative/dir"], key: key).enabled)
        #expect(!QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path],
            key: Data(repeating: 1, count: 16)).enabled)
    }

    /// Round-4 finding 1: the key is never taken from the environment (or a key
    /// file named there); only the key the worker received on its input counts.
    @Test func aKeyInTheEnvironmentIsNeverUsed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hex = String(repeating: "0f", count: 32)
        let keyFile = root.appendingPathComponent("key")
        try Data(hex.utf8).write(to: keyFile)
        chmod(keyFile.path, 0o600)
        for environment in [["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path, "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY": hex],
                            ["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path, "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY_FILE": keyFile.path]] {
            let value = QwenStagePrefixDiskConfiguration.fromEnvironment(environment, key: nil)
            #expect(!value.enabled)
            if case .off(let sweep, let reason) = value.mode {
                #expect(sweep?.path == root.standardizedFileURL.path && reason == "no usable key")
            }
        }
        let supplied = Data(repeating: 0xab, count: 32)
        let input = QwenStagePrefixDiskConfiguration.fromEnvironment(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": root.path,
            "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY": hex], key: supplied)
        if case .on(_, let key) = input.mode { #expect(key == supplied) } else { Issue.record("the supplied key did not turn the tier on") }
    }

    @Test func aRecordSurvivesARestartAndRestoresExactlyAtEachKeptFrontier() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(100..<140), scope = "scope|chunk=8"
        let captured = states(committed: 39, frontiers: [8, 16, 24, 32], seed: 1)
        do {
            let tier = try openTier(configuration(root))
            tier.persist(scope: scope, tokens: tokens, states: captured, blockTokens: block)
            #expect(tier.drain(timeoutSeconds: 20))
            #expect(tier.stats.persisted == 1 && tier.recordCount == 1)
            // Kept: N-1 and the disk grid (stride 16), not every resident frontier.
            #expect(tier.frontiers(scope: scope, tokens: tokens, maximumFrontier: 39) == [39, 32, 16])
            tier.close()
        }
        // A new process: same plan, same key.
        let tier = try openTier(configuration(root))
        #expect(tier.stats.loadedRecords == 1)
        #expect(tier.frontiers(scope: scope, tokens: tokens, maximumFrontier: 38) == [32, 16])
        #expect(tier.frontiers(scope: "other", tokens: tokens, maximumFrontier: 39).isEmpty)
        var changed = tokens; changed[20] = 7
        #expect(tier.frontiers(scope: scope, tokens: changed, maximumFrontier: 39) == [16])
        for frontier in [39, 32, 16] {
            let restored = try #require(try tier.restore(scope: scope, tokens: tokens, frontier: frontier, check: {}))
            let original = captured.first { $0.committedTokens == frontier }!
            #expect(same(restored, original))
        }
        #expect(tier.stats.restores == 3)
        // A frontier the record does not keep is not restorable.
        #expect(try tier.restore(scope: scope, tokens: tokens, frontier: 24, check: {}) == nil)
        // The same prompt again only touches its record.
        tier.persist(scope: scope, tokens: tokens, states: captured, blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20))
        #expect(tier.stats.persisted == 0 && tier.recordCount == 1)
        // Files are named by keyed tags and private to this user.
        let directory = tier.directory
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".dbpx") }
        #expect(names.count == 1 && !names[0].contains(QwenStagePrefixCache.key(scope: scope, tokens: tokens[0..<39]).prefix(16)))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(names[0]).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func offersCarryTierBitsAndTheChoiceIgnoresThem() {
        let a = QwenStagePrefixOffer(enabled: true, frontiers: [99, 64, 32], onDisk: [99])
        let decoded = QwenStagePrefixOffer(words: a.words, promptCount: 100)
        #expect(decoded == a && decoded.onDisk == [99])
        let b = QwenStagePrefixOffer(enabled: true, frontiers: [99, 32], onDisk: [32])
        #expect(QwenStagePrefixChoice.choose(local: a, peer: b, promptCount: 100) == .init(reusedPrefix: 99, splitFinalToken: true))
        #expect(QwenStagePrefixChoice.choose(local: b, peer: a, promptCount: 100) == .init(reusedPrefix: 99, splitFinalToken: true))
        // A tier bit on an out-of-range value, duplicates, or the old magic: off.
        var words = a.words; words[3] = Int32(100) | QwenStagePrefixOffer.diskBit
        #expect(QwenStagePrefixOffer(words: words, promptCount: 100) == .init(enabled: false, frontiers: []))
        words = a.words; words[4] = words[3]
        #expect(QwenStagePrefixOffer(words: words, promptCount: 100) == .init(enabled: false, frontiers: []))
        words = a.words; words[0] = 0x5046_5831
        #expect(QwenStagePrefixOffer(words: words, promptCount: 100) == .init(enabled: false, frontiers: []))
    }

    @Test func aChangedByteMakesTheRecordAbsentAndItIsDeleted() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(0..<40), scope = "s"
        let tier = try openTier(configuration(root))
        tier.persist(scope: scope, tokens: tokens, states: states(committed: 39, frontiers: [16], seed: 2), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20))
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).first { $0.hasSuffix(".dbpx") })
        let url = tier.directory.appendingPathComponent(name)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 40] ^= 0x01
        try bytes.write(to: url)
        #expect(try tier.restore(scope: scope, tokens: tokens, frontier: 39, check: {}) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(tier.frontiers(scope: scope, tokens: tokens, maximumFrontier: 39).isEmpty)
        #expect(tier.stats.failedRestores == 1)
    }

    @Test func anotherKeyAnotherPlanOrTheSwitchSweepsWhatCannotBeUsed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(0..<40)
        let unrelated = root.appendingPathComponent("not-ours", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let first = try openTier(configuration(root), plan: "plan-a")
        first.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 3), blockTokens: block)
        #expect(first.drain(timeoutSeconds: 20))
        first.close()
        // Another key: every record of this rank is unreadable and deleted.
        let rekeyed = try openTier(configuration(root, key: Data(repeating: 9, count: 32)), plan: "plan-a")
        #expect(rekeyed.recordCount == 0 && rekeyed.stats.sweptFiles >= 1)
        rekeyed.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 3), blockTokens: block)
        #expect(rekeyed.drain(timeoutSeconds: 20))
        rekeyed.close()
        let planA = root.appendingPathComponent(QwenStagePrefixDiskTier.planDirectoryName(scope: "plan-a"))
        #expect(FileManager.default.fileExists(atPath: planA.path))
        // Another plan on this rank: plan-a's live record is kept (a switch back
        // restores it, finding F5/S4) inside the budget; unrelated files stay.
        let other = try openTier(configuration(root, key: Data(repeating: 9, count: 32)), plan: "plan-b")
        #expect(other.stats.sweptPlans == 0 && FileManager.default.fileExists(atPath: planA.path))
        #expect(other.stats.keptOtherRecords == 1 && other.stats.keptOtherBytes > 0)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        other.close()
        // Switched off with a root: every plan directory goes.
        #expect(QwenStagePrefixDiskTier.open(configuration: .init(mode: .off(sweepRoot: root, reason: "switched off")),
            planScope: "plan-b", rank: 0) == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left == ["not-ours"])
    }

    @Test func aPlanDirectoryALiveRankUsesIsNotSweptAndLongPromptsKeepABoundedGrid() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try openTier(configuration(root), plan: "plan-live")
        let other = try openTier(configuration(root), plan: "plan-other")
        let liveDirectory = root.appendingPathComponent(QwenStagePrefixDiskTier.planDirectoryName(scope: "plan-live"))
        #expect(other.stats.sweptPlans == 0 && FileManager.default.fileExists(atPath: liveDirectory.path))
        live.close()
        other.close()
        let third = try openTier(configuration(root) { $0.strideTokens = 2 }, plan: "plan-third")
        #expect(third.stats.sweptPlans == 2 && !FileManager.default.fileExists(atPath: liveDirectory.path))
        // Every 2 tokens captured, a 2-token disk stride: doubled until at most 8 grid frontiers remain.
        let tokens = Array(0..<40)
        third.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: Array(stride(from: 2, through: 38, by: 2)), seed: 5),
            blockTokens: 2)
        #expect(third.drain(timeoutSeconds: 20))
        #expect(third.frontiers(scope: "s", tokens: tokens, maximumFrontier: 39) == [39, 32, 24, 16, 8])
        third.close()
    }

    @Test func evictionIsByRecordCountInRecencyOrderAndRecordsExpire() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tier = try openTier(configuration(root) { $0.recordLimit = 2 })
        let prompts = (0..<3).map { p in Array((p * 1000)..<(p * 1000 + 40)) }
        tier.persist(scope: "s", tokens: prompts[0], states: states(committed: 39, frontiers: [], seed: 0), blockTokens: block)
        tier.persist(scope: "s", tokens: prompts[1], states: states(committed: 39, frontiers: [], seed: 1), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20))
        // Use the first, then add a third: the second (least recently used) goes.
        #expect(try tier.restore(scope: "s", tokens: prompts[0], frontier: 39, check: {}) != nil)
        tier.persist(scope: "s", tokens: prompts[2], states: states(committed: 39, frontiers: [], seed: 2), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20))
        #expect(tier.recordCount == 2 && tier.stats.evictions == 1)
        #expect(tier.frontiers(scope: "s", tokens: prompts[1], maximumFrontier: 39).isEmpty)
        #expect(tier.frontiers(scope: "s", tokens: prompts[0], maximumFrontier: 39) == [39])
        // Thirty-one minutes later nothing is offered, and a restart deletes them.
        let later = Date().timeIntervalSince1970 + 31 * 60
        tier.now = { later }
        #expect(tier.frontiers(scope: "s", tokens: prompts[0], maximumFrontier: 39).isEmpty)
        tier.close()
        usleep(1_100_000)
        let expired = try openTier(configuration(root) { $0.ttlSeconds = 1 })
        #expect(expired.recordCount == 0 && expired.stats.expirations == 2)
    }

    @Test func writesAreBoundedAndNeverWaitedFor() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(0..<40)
        // Below the shortest prompt worth a record: nothing.
        let short = try openTier(configuration(root) { $0.minimumTokens = 64 })
        short.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 0), blockTokens: block)
        #expect(short.drain(timeoutSeconds: 20) && short.recordCount == 0 && short.stats.droppedPersists == 0)
        short.close()
        // No room behind the writer: dropped.
        let full = try openTier(configuration(root) { $0.maximumQueuedJobs = 0 })
        full.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 0), blockTokens: block)
        #expect(full.drain(timeoutSeconds: 20) && full.recordCount == 0 && full.stats.droppedPersists == 1)
        full.close()
        // Below the free-space floor or past the daily cap: dropped by the writer.
        let low = try openTier(configuration(root) { $0.minimumFreeBytes = Int.max / 4 })
        low.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 0), blockTokens: block)
        #expect(low.drain(timeoutSeconds: 20) && low.recordCount == 0 && low.stats.droppedPersists == 1)
        low.close()
        let capped = try openTier(configuration(root) { $0.maximumWriteBytesPerDay = 1 })
        capped.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 0), blockTokens: block)
        #expect(capped.drain(timeoutSeconds: 20) && capped.recordCount == 0 && capped.stats.droppedPersists == 1)
        capped.close()
    }

    @Test func qualificationFaultsKeepTheRecordAndACheckFailureThrows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(0..<40)
        let writer = try openTier(configuration(root))
        writer.persist(scope: "s", tokens: tokens, states: states(committed: 39, frontiers: [], seed: 4), blockTokens: block)
        #expect(writer.drain(timeoutSeconds: 20))
        writer.close()
        let failing = try openTier(configuration(root), fault: .init(restoreFails: true))
        #expect(try failing.restore(scope: "s", tokens: tokens, frontier: 39, check: {}) == nil)
        #expect(failing.recordCount == 1)
        failing.close()
        let stalled = try openTier(configuration(root), fault: .init(restoreStallMilliseconds: 5_000))
        var calls = 0
        #expect(throws: ProbeError.self) {
            _ = try stalled.restore(scope: "s", tokens: tokens, frontier: 39, check: {
                calls += 1; if calls > 3 { throw ProbeError("peer ended") }
            })
        }
        #expect(stalled.recordCount == 1)
        stalled.fault = nil
        #expect(try stalled.restore(scope: "s", tokens: tokens, frontier: 39, check: {}) != nil)
        // The switch names are admitted by the qualification fault parser only.
        #expect(try QwenPhaseSplitFault.admit(environment: ["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": "prefix_ssd_restore_fail=1"])?
            .prefixDisk == .init(restoreFails: true))
        #expect(try QwenPhaseSplitFault.admit(environment: ["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": "prefix_ssd_restore_stall=250"])?
            .prefixDisk == .init(restoreStallMilliseconds: 250))
        #expect(throws: ProbeError.self) {
            _ = try QwenPhaseSplitFault.admit(environment: ["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": "prefix_ssd_restore_fail=2"])
        }
    }

    // MARK: full caching (work/cluster-full-caching)

    @Test func aRecordCarriesTheSpeculativeHistoryAtTheFrontiersThatHaveOne() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(200..<240), scope = "scope|chunk=8"
        var captured = states(committed: 39, frontiers: [16, 32], seed: 6)
        // The decoding rank keeps the head's history at N-1 and at the grid frontier 32, not at 16.
        for index in captured.indices where [39, 32].contains(captured[index].committedTokens) {
            captured[index].speculativeHistory = history(frontier: captured[index].committedTokens, seed: captured[index].committedTokens)
        }
        do {
            let tier = try openTier(configuration(root))
            tier.persist(scope: scope, tokens: tokens, states: captured, blockTokens: block)
            #expect(tier.drain(timeoutSeconds: 20) && tier.stats.persisted == 1)
            tier.close()
        }
        let tier = try openTier(configuration(root))
        #expect(tier.frontiers(scope: scope, tokens: tokens, maximumFrontier: 39) == [39, 32, 16])
        for frontier in [39, 32, 16] {
            let restored = try #require(try tier.restore(scope: scope, tokens: tokens, frontier: frontier, check: {}))
            let original = captured.first { $0.committedTokens == frontier }!
            #expect(same(restored, original))
            #expect(sameHistory(restored.speculativeHistory, original.speculativeHistory))
            #expect((restored.speculativeHistory == nil) == (frontier == 16))
        }
        // A history that does not describe its frontier is refused before anything is written.
        var wrong = states(committed: 39, frontiers: [], seed: 7)
        wrong[0].speculativeHistory = history(frontier: 20, seed: 1)
        let other = Array(300..<340)
        tier.persist(scope: scope, tokens: other, states: wrong, blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20))
        #expect(tier.frontiers(scope: scope, tokens: other, maximumFrontier: 39).isEmpty && tier.stats.droppedPersists == 1)
        tier.close()
    }

    @Test func closeFinishesQueuedWritesAndExtendsItsBoundOnlyOnProgress() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tier = try openTier(configuration(root) { $0.maximumQueuedJobs = 4 })
        let prompts = (0..<3).map { p in Array((p * 1000)..<(p * 1000 + 40)) }
        for (seed, prompt) in prompts.enumerated() {
            tier.persist(scope: "s", tokens: prompt, states: states(committed: 39, frontiers: [16], seed: seed), blockTokens: block)
        }
        // No drain first: the teardown itself must let the queued records land.
        tier.close()
        #expect(tier.recordCount == 3 && tier.stats.persisted == 3 && tier.stats.closeDrained && !tier.stats.closeExtended)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).filter { $0.hasPrefix(".") }.isEmpty)
        // After close nothing more is accepted.
        tier.persist(scope: "s", tokens: Array(5000..<5040), states: states(committed: 39, frontiers: [], seed: 9), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20) && tier.recordCount == 3 && tier.stats.droppedPersists == 1)
        // The rule: one extension when a record completed since the close began; none when nothing did.
        let began: TimeInterval = 1_000
        #expect(QwenStagePrefixDiskTier.teardownExtends(drained: false, lastCompletedWrite: began + 12, closeBegan: began, boundSeconds: 20))
        #expect(QwenStagePrefixDiskTier.teardownExtends(drained: false, lastCompletedWrite: began, closeBegan: began, boundSeconds: 20))
        #expect(!QwenStagePrefixDiskTier.teardownExtends(drained: false, lastCompletedWrite: began - 1, closeBegan: began, boundSeconds: 20))
        #expect(!QwenStagePrefixDiskTier.teardownExtends(drained: false, lastCompletedWrite: nil, closeBegan: began, boundSeconds: 20))
        #expect(!QwenStagePrefixDiskTier.teardownExtends(drained: true, lastCompletedWrite: began + 12, closeBegan: began, boundSeconds: 20))
        #expect(!QwenStagePrefixDiskTier.teardownExtends(drained: false, lastCompletedWrite: began + 12, closeBegan: began, boundSeconds: 0))
    }

    @Test func recordsAreStagedUnderTheSessionEpochAndEachCompletedWriteStampsProgress() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = UUID().uuidString.lowercased()
        let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan-a", rank: 0,
            stagingEpoch: epoch))
        let epochDirectory = QwenStagePrefixDiskTier.stagingRoot(root: root).appendingPathComponent(epoch, isDirectory: true)
        let staging = epochDirectory.appendingPathComponent("rank0", isDirectory: true)
        #expect(tier.stagingDirectory == staging)
        // The other rank of the same session on the same Mac (shared root and epoch) stages beside it.
        let peer = try #require(QwenStagePrefixDiskTier.open(configuration: configuration(root), planScope: "plan-a", rank: 1,
            stagingEpoch: epoch))
        peer.persist(scope: "s", tokens: Array(0..<40), states: states(committed: 39, frontiers: [16], seed: 5), blockTokens: block)
        #expect(peer.drain(timeoutSeconds: 20) && peer.recordCount == 1)
        let before = ProcessForcedExit.lastProgressUptimeNanoseconds
        tier.persist(scope: "s", tokens: Array(0..<40), states: states(committed: 39, frontiers: [16], seed: 3), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20) && tier.recordCount == 1)
        // The completed record stamped the dead-man's progress word.
        #expect(ProcessForcedExit.lastProgressUptimeNanoseconds > before)
        // Nothing half-written stays: not in the rank directory, not in the staging directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).filter { $0.hasPrefix(".") }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        // A staging directory the reaper removed while idle is recreated by the next write.
        try FileManager.default.removeItem(at: staging)
        tier.persist(scope: "s", tokens: Array(100..<140), states: states(committed: 39, frontiers: [], seed: 4), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20) && tier.recordCount == 2)
        // Close removes this rank's staging directory and never the other rank's (found on real weights: rank 0's
        // close removed rank 1's in-flight write when both staged in one directory); the records stay.
        tier.close()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: epochDirectory.appendingPathComponent("rank1").path))
        peer.close()
        #expect(!FileManager.default.fileExists(atPath: epochDirectory.path))
        #expect(FileManager.default.fileExists(atPath: QwenStagePrefixDiskTier.stagingRoot(root: root).path))
        // Only a lowercase UUID names a staging directory; anything else stages beside the record.
        #expect(QwenStagePrefixDiskTier.stagingName(epoch: epoch.uppercased()) == nil)
        #expect(QwenStagePrefixDiskTier.stagingName(epoch: "../x") == nil && QwenStagePrefixDiskTier.stagingName(epoch: nil) == nil)
        // The staging root is not a plan directory: opening another plan never sweeps it.
        #expect(!QwenStagePrefixDiskTier.isPlanDirectoryName(QwenStagePrefixDiskTier.stagingDirectoryName))
    }

    @Test func onlyPromptFrontiersAreOfferedOrPersisted() throws {
        // The accepted timeline only (oMLX mtp-terminal-commit): a frontier at
        // or past the prompt (generated tokens) is never offered, and a state
        // deeper than the prompt is never written.
        let atPrompt = QwenStagePrefixOffer(enabled: true, frontiers: [100, 64])
        #expect(QwenStagePrefixOffer(words: atPrompt.words, promptCount: 100) == .init(enabled: false, frontiers: []))
        #expect(QwenStagePrefixOffer(words: atPrompt.words, promptCount: 101) == atPrompt)
        #expect(QwenStagePrefixChoice.choose(local: atPrompt, peer: atPrompt, promptCount: 100) == .init(reusedPrefix: 64, splitFinalToken: true))
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tier = try openTier(configuration(root))
        let tokens = Array(0..<40)
        tier.persist(scope: "s", tokens: tokens, states: states(committed: 41, frontiers: [], seed: 1), blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20) && tier.recordCount == 0 && tier.stats.persisted == 0)
        tier.close()
    }

    @Test func aPromotedDiskRestoreIsChargedToTheResidentBudgetInFull() throws {
        // F1 accounting: a state read from the SSD tier and promoted to the
        // resident tier counts its attention copy, recurrent state and
        // speculative history, exactly as a captured prompt does, and gives
        // way under the budget as any entry.
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(0..<40), scope = "s"
        var captured = states(committed: 39, frontiers: [], seed: 3)
        captured[0].speculativeHistory = history(frontier: 39, seed: 2)
        let tier = try openTier(configuration(root))
        tier.persist(scope: scope, tokens: tokens, states: captured, blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20))
        let restored = try #require(try tier.restore(scope: scope, tokens: tokens, frontier: 39, check: {}))
        let expected = restored.attention.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
            + restored.recurrent.values.reduce(0) { $0 + $1.conv.nbytes + $1.ssm.nbytes }
            + history(frontier: 39, seed: 2).hidden.nbytes + history(frontier: 39, seed: 2).tokens.nbytes + history(frontier: 39, seed: 2).last.nbytes
        #expect(restored.sharedBytes + restored.ownBytes == expected)
        let resident = QwenStagePrefixCache(enabled: true)
        resident.setBudget(expected * 2)
        resident.insert(scope: scope, tokens: tokens, states: [restored], sharedBytes: restored.sharedBytes)
        #expect(resident.bytesInUse == expected && resident.count == 1)
        #expect(resident.state(scope: scope, tokens: tokens, frontier: 39)?.speculativeHistory != nil)
        // Under a budget below the promoted state, it is evicted like any entry (never over budget).
        resident.setBudget(expected - 1)
        #expect(resident.bytesInUse == 0 && resident.count == 0)
        tier.close()
    }

    /// Finding S3: the rolling-day write counter is saved as "<start> <bytes>\n"
    /// and was parsed with the newline still on the bytes, so every reopen
    /// started the day at zero and the daily cap held per process. It now
    /// survives a reopen and still refuses a write past the cap. Finding S7:
    /// the counter and the key check are owner-only, as the records are.
    @Test func theDailyWriteWindowSurvivesAReopenAndStillRefusesPastTheCap() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try openTier(configuration(root))
        first.persist(scope: "s", tokens: Array(0..<40), states: states(committed: 39, frontiers: [], seed: 1), blockTokens: block)
        #expect(first.drain(timeoutSeconds: 20) && first.recordCount == 1)
        let windowURL = first.directory.appendingPathComponent("write-window")
        let saved = try String(contentsOf: windowURL, encoding: .utf8)
        let parts = saved.split(whereSeparator: { $0.isWhitespace })
        let start = try #require(Double(parts[0])), bytes = try #require(Int(parts[1]))
        #expect(bytes == first.stats.persistedBytes)
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: first.directory.path).first { $0.hasSuffix(".dbpx") })
        let data = try QwenStagePrefixDiskIO.open(url: first.directory.appendingPathComponent(name),
            keys: QwenStagePrefixDiskKeys(master: Data(repeating: 7, count: 32))).header.dataBytes
        for file in ["write-window", "key-check"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: first.directory.appendingPathComponent(file).path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
        first.close()
        // Reopened the same day with a cap one byte short of a second record of
        // the same shape: the saved bytes count, so the writer refuses it.
        let capped = try openTier(configuration(root) { $0.maximumWriteBytesPerDay = data + 64 * 1024 + bytes - 1 })
        capped.persist(scope: "s", tokens: Array(1000..<1040), states: states(committed: 39, frontiers: [], seed: 2), blockTokens: block)
        #expect(capped.drain(timeoutSeconds: 20))
        #expect(capped.recordCount == 1 && capped.stats.droppedPersists == 1 && capped.stats.persisted == 0)
        capped.close()
        // With room under the same cap plus one record, the window keeps adding on.
        let roomy = try openTier(configuration(root) { $0.maximumWriteBytesPerDay = data + 64 * 1024 + bytes })
        roomy.persist(scope: "s", tokens: Array(2000..<2040), states: states(committed: 39, frontiers: [], seed: 3), blockTokens: block)
        #expect(roomy.drain(timeoutSeconds: 20) && roomy.stats.persisted == 1)
        let after = try String(contentsOf: windowURL, encoding: .utf8).split(whereSeparator: { $0.isWhitespace })
        #expect(Double(after[0]) == start && Int(after[1]) == bytes + roomy.stats.persistedBytes)
        roomy.close()
    }

    /// Finding R2: unit reads were F_NOCACHE preads at misaligned offsets into
    /// unaligned buffers, which leaves larger units in the page cache. Every
    /// unit is now read through its page-aligned superset into page-aligned
    /// memory, and the restored state is unchanged.
    @Test func restoreReadsArePageAlignedAndExact() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(400..<440), scope = "s"
        var captured = states(committed: 39, frontiers: [16, 32], seed: 8)
        for index in captured.indices where captured[index].committedTokens == 39 {
            captured[index].speculativeHistory = history(frontier: 39, seed: 4)
        }
        let tier = try openTier(configuration(root))
        tier.persist(scope: scope, tokens: tokens, states: captured, blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20) && tier.recordCount == 1)
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).first { $0.hasSuffix(".dbpx") })
        let url = tier.directory.appendingPathComponent(name)
        let opened = try QwenStagePrefixDiskIO.open(url: url, keys: QwenStagePrefixDiskKeys(master: Data(repeating: 7, count: 32)))
        #expect(opened.dataStart % QwenStagePrefixDiskIO.readAlignment != 0)
        final class Reads: @unchecked Sendable {
            let lock = NSLock(); var calls: [(offset: Int, buffer: UInt)] = []
        }
        for frontier in [39, 32, 16] {
            let reads = Reads()
            let restored = try QwenStagePrefixDiskIO.restore(url: url, opened: opened, frontier: frontier,
                readCall: { fd, buffer, count, offset in
                    reads.lock.withLock { reads.calls.append((Int(offset), UInt(bitPattern: buffer))) }
                    return Darwin.pread(fd, buffer, count, offset)
                }, check: {})
            let original = captured.first { $0.committedTokens == frontier }!
            #expect(same(restored, original) && sameHistory(restored.speculativeHistory, original.speculativeHistory))
            #expect(!reads.calls.isEmpty)
            #expect(reads.calls.allSatisfy { $0.offset % QwenStagePrefixDiskIO.readAlignment == 0
                && $0.buffer % UInt(QwenStagePrefixDiskIO.readAlignment) == 0 })
        }
        // The superset of a range: aligned down and up, clipped at the end of the file.
        #expect(QwenStagePrefixDiskIO.alignedExtent(start: 37_982, length: 1_048_592, fileSize: 2_000_000) == (32_768, 1_064_960))
        #expect(QwenStagePrefixDiskIO.alignedExtent(start: 16_384, length: 16_384, fileSize: 40_000) == (16_384, 16_384))
        #expect(QwenStagePrefixDiskIO.alignedExtent(start: 30_000, length: 9_000, fileSize: 39_000) == (16_384, 22_616))
        tier.close()
    }

    /// Finding storage:S2 / reads:R6: the decoding rank's speculative history
    /// at each kept frontier is a view of one kept copy (the decoder's
    /// `prefixHistory(at:)`), and version 1 wrote a whole copy per frontier.
    /// A record now stores it once (rows of the deepest history in block
    /// units, and its tokens) and every frontier restores exactly the view it
    /// had; histories that are not views of one copy keep version 1.
    @Test func theSpeculativeHistoryIsStoredOncePerRecordAndRestoresExactly() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = Array(500..<540), scope = "scope|chunk=8", prompt = 40, width = 4
        // One kept copy as the decoder holds it: hidden [1, prompt-1, 4], tokens [1, prompt-1], last [1, 1, 4].
        let keptHidden = (MLXArray(0..<((prompt - 1) * width)).asType(.float32) * 0.5 + 3).reshaped([1, prompt - 1, width]).asType(.bfloat16)
        let keptTokens = MLXArray((1..<prompt).map { Int32($0 * 3) }).reshaped([1, prompt - 1])
        let keptLast = (MLXArray(0..<width).asType(.float32) - 9).reshaped([1, 1, width]).asType(.bfloat16)
        eval(keptHidden, keptTokens, keptLast)
        var captured = states(committed: 39, frontiers: [16, 32], seed: 11)
        for index in captured.indices {
            captured[index].speculativeHistory = QwenMTPPrefixHistory.view(hidden: keptHidden, tokens: keptTokens, last: keptLast,
                prompt: prompt, frontier: captured[index].committedTokens)
        }
        let tier = try openTier(configuration(root))
        tier.persist(scope: scope, tokens: tokens, states: captured, blockTokens: block)
        #expect(tier.drain(timeoutSeconds: 20) && tier.recordCount == 1)
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: tier.directory.path).first { $0.hasSuffix(".dbpx") })
        let opened = try QwenStagePrefixDiskIO.open(url: tier.directory.appendingPathComponent(name),
            keys: QwenStagePrefixDiskKeys(master: Data(repeating: 7, count: 32)))
        #expect(opened.header.version == 2)
        // Attention (2 x heads x 39 rows) and recurrent units as before; the history once:
        // 39 hidden rows plus the last row, and 38 tokens, instead of three copies.
        let tag = QwenStagePrefixDiskFormat.tagBytes, row = width * 2
        let attention = 2 * ((39 + block - 1) / block) * tag + 2 * heads * 39 * headDim * 2
        let recurrent = 3 * (2 * tag + 12 * 4 + 16 * 4)
        let once = ((39 + block - 1) / block) * tag + 39 * row + (38 * 4 + tag)
        #expect(opened.header.dataBytes == attention + recurrent + once)
        for frontier in [39, 32, 16] {
            let restored = try #require(try tier.restore(scope: scope, tokens: tokens, frontier: frontier, check: {}))
            let original = captured.first { $0.committedTokens == frontier }!
            #expect(same(restored, original))
            #expect(sameHistory(restored.speculativeHistory, original.speculativeHistory))
        }
        tier.close()
    }

    /// Finding F5/S4: opening another plan (a model, mode, cut or build switch)
    /// deleted every other plan's records on the Mac, so switching back started
    /// cold. Other plans' live records are now kept inside this rank's one
    /// budget: a switch back restores them; when all plans together exceed the
    /// budget the other plans' oldest records go first; expired ones and the
    /// directories they leave empty go at load.
    @Test func aPlanSwitchKeepsTheOtherPlansLiveRecordsWithinOneBudget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokensA = Array(0..<40), tokensB = Array(1000..<1040)
        let first = try openTier(configuration(root), plan: "model-a")
        first.persist(scope: "s", tokens: tokensA, states: states(committed: 39, frontiers: [16], seed: 1), blockTokens: block)
        #expect(first.drain(timeoutSeconds: 20) && first.recordCount == 1)
        let recordBytes = first.stats.persistedBytes
        first.close()
        let planA = root.appendingPathComponent(QwenStagePrefixDiskTier.planDirectoryName(scope: "model-a"))
        // The other model loads and serves: model-a's record stays on disk.
        let second = try openTier(configuration(root), plan: "model-b")
        #expect(FileManager.default.fileExists(atPath: planA.path))
        second.persist(scope: "s", tokens: tokensB, states: states(committed: 39, frontiers: [16], seed: 2), blockTokens: block)
        #expect(second.drain(timeoutSeconds: 20) && second.recordCount == 1)
        second.close()
        // Switching back restores model-a's prompt from the SSD tier.
        let back = try openTier(configuration(root), plan: "model-a")
        #expect(back.frontiers(scope: "s", tokens: tokensA, maximumFrontier: 39) == [39, 16])
        #expect(try back.restore(scope: "s", tokens: tokensA, frontier: 39, check: {}) != nil)
        back.close()
        // One budget for all plans: with room for about one record, model-a's
        // load drops model-b's (the other plan's) record first and keeps its own.
        let tight = try openTier(configuration(root) { $0.byteBudget = recordBytes + recordBytes / 2 }, plan: "model-a")
        #expect(tight.recordCount == 1 && tight.frontiers(scope: "s", tokens: tokensA, maximumFrontier: 39).first == 39)
        let planB = root.appendingPathComponent(QwenStagePrefixDiskTier.planDirectoryName(scope: "model-b"))
        let planBRecords = try FileManager.default.contentsOfDirectory(atPath: planB.appendingPathComponent("rank0").path)
            .filter { $0.hasSuffix(".dbpx") }
        #expect(planBRecords.isEmpty)
        tight.close()
        // Past the TTL another plan's records are deleted at load, and its directory with them.
        usleep(1_100_000)
        let later = try openTier(configuration(root) { $0.ttlSeconds = 1 }, plan: "model-c")
        #expect(!FileManager.default.fileExists(atPath: planA.path) && !FileManager.default.fileExists(atPath: planB.path))
        later.close()
    }
}
