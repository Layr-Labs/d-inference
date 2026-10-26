import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

// The SSD tier of GLM tensor parallel's prompt-prefix cache
// (`GLM5NextTensorParallelPrefixDisk`), with synthetic rank states: records
// through the encrypted tier and a restart, the record scope, budgets and
// expiry, records that do not adopt, the two-tier vote and its confirmation
// across two ranks. Arrays are host constants read on the CPU device; no
// model, no pair.

private func glmRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glm-prefix-ssd-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func glmConfiguration(_ root: URL, _ change: (inout QwenStagePrefixDiskConfiguration) -> Void = { _ in })
    -> QwenStagePrefixDiskConfiguration {
    var value = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: 0x5a, count: 32)))
    value.minimumTokens = 1; value.minimumFreeBytes = 1
    change(&value)
    return value
}

@Suite("GLM tensor-parallel prefix SSD tier", .serialized)
struct GLM5NextTensorParallelPrefixDiskTests {
    typealias Record = GLM5NextTensorParallelPrefixRecord
    typealias Disk = GLM5NextTensorParallelPrefixDisk
    typealias Vote = QwenTensorParallelPrefixCache

    /// A rank of an eight-layer stage: DSA layers 3 and 7, the NextN layer 8,
    /// two KDA heads of width 2 (bfloat16 histories, as the artifact's).
    static let layout = Record.Layout(firstLayer: 0, dsaLayers: [3, 7], kdaLayers: [0, 1, 2, 4, 5, 6],
        latentWidth: 8, keyWidth: 4, historyTypes: [.bfloat16, .bfloat16, .bfloat16], nextNLayer: 8,
        nextNTypes: [.bfloat16, .bfloat16, .bfloat16], convolutionShape: [1, 12, 4], recurrentShape: [1, 2, 2, 2],
        paged: true)
    static let chunk = 8
    static let artifact = String(repeating: "a", count: 64), inventory = String(repeating: "b", count: 64)
    static let builds = [String(repeating: "1", count: 64), String(repeating: "2", count: 64)]
    static var planScope: String {
        Disk.planScope(artifactAggregateSHA256: artifact, inventorySHA256: inventory, rankBuildSHA256: builds, mtpDepth: 2)
    }

    /// Rows of `width` 16-bit elements, deterministic in `seed`.
    static func plane(rows: Int, width: Int, seed: Int) -> Data {
        var data = Data(count: rows * width * 2)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt16.self)
            for index in 0 ..< rows * width { words[index] = UInt16(truncatingIfNeeded: (index &* 40_503 &+ seed &* 977) >> 3) }
        }
        return data
    }

    static func source(_ data: Data, width: Int, rows: Int) -> QwenStagePrefixDiskRows {
        let row = width * 2
        return .init(dtype: .bfloat16, tokens: rows, width: width, heldBytes: data.count, read: { range, destination in
            data.withUnsafeBytes {
                destination.copyMemory(from: $0.baseAddress!.advanced(by: range.lowerBound * row), byteCount: range.count * row)
            }
        })
    }

    /// One rank's synthetic state at `frontier`: its record (KDA states and
    /// history readers) and the planes the histories hold.
    struct Synthetic {
        let state: QwenStagePrefixState
        let rows: [Int: Record.Rows]
        let keys: [Int: Data]
        let values: [Int: Data]
    }

    static func synthetic(frontier: Int, seed: Int, layout: Record.Layout = layout) -> Synthetic {
        var rows: [Int: Record.Rows] = [:], keys: [Int: Data] = [:], values: [Int: Data] = [:]
        for layer in layout.dsaLayers + (layout.nextNLayer.map { [$0] } ?? []) {
            let k = plane(rows: frontier, width: layout.latentWidth, seed: seed * 31 + layer)
            let v = plane(rows: frontier, width: 2 * layout.keyWidth, seed: seed * 37 + layer + 1_000)
            rows[layer] = (source(k, width: layout.latentWidth, rows: frontier),
                           source(v, width: 2 * layout.keyWidth, rows: frontier))
            keys[layer] = k; values[layer] = v
        }
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for layer in layout.kdaLayers {
            let conv = MLXArray((0 ..< 48).map { Float($0 * 3 + layer + seed) }, layout.convolutionShape).asType(.bfloat16)
            let ssm = MLXArray((0 ..< 8).map { Float($0 - layer) * 0.5 + Float(seed) }, layout.recurrentShape)
            recurrent[layer] = (conv, ssm)
        }
        return .init(state: QwenStagePrefixState(committedTokens: frontier, attention: [:], recurrent: recurrent),
            rows: rows, keys: keys, values: values)
    }

    static func bytes(_ array: MLXArray) -> Data { array.asData(access: .copy).data }

    static func openDisk(_ root: URL, rank: Int = 0, epoch: UUID = UUID(), layout: Record.Layout = layout,
                         _ change: (inout QwenStagePrefixDiskConfiguration) -> Void = { _ in }) throws -> Disk {
        let tier = try #require(QwenStagePrefixDiskTier.open(configuration: glmConfiguration(root, change),
            planScope: planScope, rank: rank, stagingEpoch: epoch.uuidString.lowercased()))
        return Disk(tier: tier, planScope: planScope, layout: layout)
    }

    static func persist(_ disk: Disk, prompt: [Int], _ record: Synthetic) {
        disk.tier.persist(scope: disk.scope(chunk: chunk), tokens: prompt, states: [record.state], blockTokens: chunk,
            attentionRows: record.rows)
    }

    /// The record a rank wrote is found by a new tier on the same directory
    /// (another session: another membership epoch), and restores every
    /// history plane and KDA state bit for bit; the history units are read
    /// from the rows' source, never held whole.
    @Test func aRankStateSurvivesARestartBitForBit() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = try glmRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let prompt = (0 ..< 37).map { 4 + ($0 * 7) % 23 }
            let record = Self.synthetic(frontier: 32, seed: 1)
            do {
                let disk = try Self.openDisk(root)
                Self.persist(disk, prompt: prompt, record)
                #expect(disk.tier.drain(timeoutSeconds: 20))
                #expect(disk.tier.stats.persisted == 1 && disk.tier.recordCount == 1)
                disk.tier.close()
            }
            let disk = try Self.openDisk(root)
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: Self.chunk)
            #expect(disk.tier.stats.loadedRecords == 1)
            #expect(disk.boundaries(scope: disk.scope(chunk: Self.chunk), prompt: prompt, candidates: candidates) == [32])
            let state = try #require(try disk.tier.restore(scope: disk.scope(chunk: Self.chunk), tokens: prompt,
                frontier: 32, check: {}))
            for layer in Self.layout.dsaLayers + [8] {
                let pair = try #require(state.attention[layer])
                #expect(pair.keys.shape == [1, 1, 32, 8] && pair.values.shape == [1, 1, 32, 8])
                #expect(Self.bytes(pair.keys) == record.keys[layer] && Self.bytes(pair.values) == record.values[layer])
            }
            for (layer, pair) in record.state.recurrent {
                let restored = try #require(state.recurrent[layer])
                #expect(Self.bytes(restored.conv) == Self.bytes(pair.conv) && restored.conv.dtype == .bfloat16)
                #expect(Self.bytes(restored.ssm) == Self.bytes(pair.ssm) && restored.ssm.dtype == .float32)
            }
            // What a request writes: latents, then index keys and pool gates
            // split from their side-by-side rows, and validity whole.
            let restorable = try Record.Restorable(state, layout: Self.layout)
            #expect(restorable.frontier == 32 && restorable.nextN != nil && restorable.states.count == 6)
            for layer in Self.layout.dsaLayers {
                let history = try #require(restorable.histories[layer])
                let packed = try #require(record.values[layer])
                var keys = Data(), gates = Data()
                for row in 0 ..< 32 {
                    keys.append(packed[(row * 16) ..< (row * 16 + 8)]); gates.append(packed[(row * 16 + 8) ..< (row * 16 + 16)])
                }
                #expect(history.map(\.shape) == [[1, 32, 8], [1, 32, 4], [1, 32, 4], [1, 32]])
                #expect(Self.bytes(history[0]) == record.keys[layer] && Self.bytes(history[1]) == keys
                    && Self.bytes(history[2]) == gates && history[3].all().item(Bool.self))
            }
        }
    }

    /// The record scope names what a restored state's bytes depend on and
    /// nothing of a session; it is not the GLM pipeline's or Qwen tensor
    /// parallel's, and a request's scope adds its grid and history storage.
    @Test func theRecordScopeIsPersistentAndItsOwn() throws {
        let scope = Self.planScope
        #expect(scope == Disk.planScope(artifactAggregateSHA256: Self.artifact, inventorySHA256: Self.inventory,
            rankBuildSHA256: Self.builds, mtpDepth: 2))
        let others = [
            Disk.planScope(artifactAggregateSHA256: Self.inventory, inventorySHA256: Self.inventory,
                rankBuildSHA256: Self.builds, mtpDepth: 2),
            Disk.planScope(artifactAggregateSHA256: Self.artifact, inventorySHA256: Self.artifact,
                rankBuildSHA256: Self.builds, mtpDepth: 2),
            Disk.planScope(artifactAggregateSHA256: Self.artifact, inventorySHA256: Self.inventory,
                rankBuildSHA256: Self.builds.reversed(), mtpDepth: 2),
            Disk.planScope(artifactAggregateSHA256: Self.artifact, inventorySHA256: Self.inventory,
                rankBuildSHA256: Self.builds, mtpDepth: 3),
            Disk.planScope(artifactAggregateSHA256: Self.artifact, inventorySHA256: Self.inventory,
                rankBuildSHA256: Self.builds, mtpDepth: 0),
            // The GLM pipeline's scope of the same artifact and builds (a cut's plan, pipeline mode).
            QwenStagePrefixDiskTier.planScope(planFingerprint: Self.inventory, artifactAggregateSHA256: Self.artifact,
                storageCommitmentSHA256: Self.inventory, rankBuildSHA256: Self.builds,
                generationMode: QwenResidentGenerationMode.pipeline.rawValue, prefillSchedule: "serial"),
            // Qwen tensor parallel's form (its plan, shares and assistant policy).
            QwenStagePrefixDiskTier.planScope(planFingerprint: [Self.inventory, "qwen_tp", "shares=1:1"].joined(separator: "|"),
                artifactAggregateSHA256: Self.artifact, storageCommitmentSHA256: Self.inventory, rankBuildSHA256: Self.builds,
                generationMode: ClusterGenerationMode.tensorParallel.rawValue, prefillSchedule: "serial|assistant=none"),
        ]
        let directory = QwenStagePrefixDiskTier.planDirectoryName(scope: scope)
        for other in others {
            #expect(other != scope && QwenStagePrefixDiskTier.planDirectoryName(scope: other) != directory)
        }
        #expect(scope.contains(GLM5NextTensorParallelResidentRuntime.planName) && scope.contains("tensor_parallel_v1"))
        let root = try glmRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try Self.openDisk(root)
        #expect(disk.scope(chunk: 4096) == scope + "|chunk=4096|kv=paged")
        let contiguous = Record.Layout(firstLayer: 0, dsaLayers: [3, 7], kdaLayers: [0, 1, 2, 4, 5, 6], latentWidth: 8,
            keyWidth: 4, historyTypes: Self.layout.historyTypes, nextNLayer: 8, nextNTypes: Self.layout.nextNTypes,
            convolutionShape: [1, 12, 4], recurrentShape: [1, 2, 2, 2], paged: false)
        #expect(Disk(tier: disk.tier, planScope: scope, layout: contiguous).scope(chunk: 4096) == scope + "|chunk=4096|kv=contiguous")
        // The tier's directory is the plan's, per rank, owner-only.
        #expect(disk.tier.directory.path.hasSuffix("/" + directory + "/rank0"))
        let attributes = try FileManager.default.attributesOfItem(atPath: disk.tier.directory.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    /// Records are found only under their own scope and prompt: another
    /// grid, history storage, plan or prompt finds nothing.
    /// A request's records live in its own partition (`prefixDiskScope`): a
    /// tenant's scope differs from the plain one and from another tenant's,
    /// so none of them is offered, read or written for another; a request
    /// that keeps no resident prefix (cache off, media) has no SSD scope.
    @Test func aRequestsRecordsAreItsOwnPartitions() throws {
        let root = try glmRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try Self.openDisk(root)
        let profile = try QwenLayerStageGenerationProfile(identifier: "glm-ssd-tenant-fixture", vocabularySize: 512,
            hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 256, maximumChunkTokens: 16,
            maximumOutputTokens: 8, maximumContextTokens: 512)
        func request(_ cache: ClusterWorkerPrefixCache?) throws -> QwenLayerStageGenerationRequest {
            try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(), promptTokenIDs: Array(0..<100),
                chunkSize: 16, outputCount: 3, stopTokenIDs: [], prefixCache: cache)
        }
        typealias Runtime = GLM5NextTensorParallelResidentRuntime
        let a = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-a"))
        let b = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-b"))
        let plain = try #require(Runtime.prefixDiskScope(disk, chunk: Self.chunk, request: try request(nil), resident: "load"))
        let scopeA = try #require(Runtime.prefixDiskScope(disk, chunk: Self.chunk, request: try request(a), resident: "load"))
        let scopeB = try #require(Runtime.prefixDiskScope(disk, chunk: Self.chunk, request: try request(b), resident: "load"))
        #expect(plain == disk.scope(chunk: Self.chunk))
        #expect(Set([plain, scopeA, scopeB]).count == 3)
        #expect(scopeA == ClusterWorkerPrefixCache.scope(disk.scope(chunk: Self.chunk), a))
        #expect(Runtime.prefixDiskScope(disk, chunk: Self.chunk, request: try request(a), resident: nil) == nil)
        #expect(Runtime.prefixDiskScope(nil, chunk: Self.chunk, request: try request(a), resident: "load") == nil)
    }

    @Test func aRecordIsFoundOnlyUnderItsScopeAndPrompt() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = try glmRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let prompt = Array(100 ..< 141)
            let disk = try Self.openDisk(root)
            Self.persist(disk, prompt: prompt, Self.synthetic(frontier: 40, seed: 2))
            #expect(disk.tier.drain(timeoutSeconds: 20))
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: Self.chunk)
            #expect(disk.boundaries(scope: disk.scope(chunk: Self.chunk), prompt: prompt, candidates: candidates) == [40])
            #expect(disk.boundaries(scope: disk.scope(chunk: 16), prompt: prompt, candidates: candidates).isEmpty)
            #expect(disk.boundaries(scope: disk.scope(chunk: Self.chunk) + "x", prompt: prompt, candidates: candidates).isEmpty)
            var other = prompt; other[39] += 1
            #expect(disk.boundaries(scope: disk.scope(chunk: Self.chunk), prompt: other, candidates: candidates).isEmpty)
            // A longer prompt with the same first 40 tokens finds it.
            let longer = prompt + [7, 8, 9]
            #expect(disk.boundaries(scope: disk.scope(chunk: Self.chunk), prompt: longer,
                candidates: QwenTensorParallelPrefixCache.candidates(promptCount: longer.count, chunk: Self.chunk)) == [40])
            disk.tier.close()
            // Another plan (another build) under the same root finds nothing.
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: glmConfiguration(root),
                planScope: Disk.planScope(artifactAggregateSHA256: Self.artifact, inventorySHA256: Self.inventory,
                    rankBuildSHA256: [Self.builds[0], String(repeating: "3", count: 64)], mtpDepth: 2), rank: 0))
            #expect(tier.recordCount == 0 && tier.stats.keptOtherRecords == 1)
        }
    }

    /// Records give way by count (least recently used first) and by bytes,
    /// expire after the sliding TTL (at a lookup and when a tier reopens),
    /// and a record bigger than the write queue's bound is dropped, never
    /// waited for.
    @Test func recordsGiveWayAndExpire() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = try glmRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let prompts = (0 ..< 3).map { lane in (0 ..< 33).map { 3 + ($0 * 5 + lane * 11) % 29 } }
            let disk = try Self.openDisk(root) { $0.recordLimit = 2 }
            let scope = disk.scope(chunk: Self.chunk)
            for (index, prompt) in prompts.prefix(2).enumerated() {
                Self.persist(disk, prompt: prompt, Self.synthetic(frontier: 32, seed: index))
                #expect(disk.tier.drain(timeoutSeconds: 20))
            }
            // The first prompt is used again: the second is now the oldest.
            disk.tier.touch(scope: scope, tokens: prompts[0], frontier: 32)
            Self.persist(disk, prompt: prompts[2], Self.synthetic(frontier: 32, seed: 2))
            #expect(disk.tier.drain(timeoutSeconds: 20))
            #expect(disk.tier.recordCount == 2 && disk.tier.stats.evictions == 1)
            func held(_ prompt: [Int]) -> Bool {
                disk.boundaries(scope: scope, prompt: prompt, candidates: [8, 16, 24, 32]) == [32]
            }
            #expect(held(prompts[0]) && !held(prompts[1]) && held(prompts[2]))
            // Past the TTL nothing is offered.
            let start = Date().timeIntervalSince1970
            disk.tier.now = { start + Double(disk.tier.configuration.ttlSeconds) + 1 }
            #expect(!held(prompts[0]) && !held(prompts[2]))
            disk.tier.now = { start }
            disk.tier.close()

            // A tier that reopens deletes what expired while it was closed.
            let aged = try Self.openDisk(root)
            aged.tier.now = { start - 2 * Double(aged.tier.configuration.ttlSeconds) }
            Self.persist(aged, prompt: Array(0 ..< 33), Self.synthetic(frontier: 32, seed: 9))
            #expect(aged.tier.drain(timeoutSeconds: 20) && aged.tier.recordCount == 3)
            aged.tier.close()
            let reopened = try Self.openDisk(root)
            #expect(reopened.tier.recordCount == 2 && reopened.tier.stats.expirations >= 1)
            reopened.tier.close()

            // A byte budget smaller than two records keeps the newest only.
            let bytes = try #require(try FileManager.default.contentsOfDirectory(atPath: reopened.tier.directory.path)
                .filter { $0.hasSuffix(".dbpx") }.map {
                    try FileManager.default.attributesOfItem(atPath: reopened.tier.directory.appendingPathComponent($0).path)[.size]
                        as? Int ?? 0
                }.max())
            let tight = try Self.openDisk(root) { $0.byteBudget = bytes + bytes / 2 }
            #expect(tight.tier.recordCount == 1)
            tight.tier.close()

            // Rows whose source keeps more alive than the queue may hold are dropped.
            let small = try Self.openDisk(root) { $0.maximumQueuedBytes = 1_024 }
            Self.persist(small, prompt: Array(50 ..< 83), Self.synthetic(frontier: 32, seed: 4))
            #expect(small.tier.drain(timeoutSeconds: 20))
            #expect(small.tier.stats.droppedPersists == 1 && small.tier.stats.persisted == 0)
        }
    }

    /// A record that does not adopt into this rank's request state (another
    /// layout: a missing NextN history, other KDA heads or widths) is
    /// refused before anything is written and deleted; an unreadable one is
    /// deleted by the tier. Either way this rank has nothing to confirm.
    @Test func aRecordThatDoesNotAdoptIsRefusedAndDeleted() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = try glmRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let prompt = Array(200 ..< 233)
            // Written by a rank without the NextN layer, read where it speculates.
            let plain = Record.Layout(firstLayer: 0, dsaLayers: [3, 7], kdaLayers: [0, 1, 2, 4, 5, 6], latentWidth: 8,
                keyWidth: 4, historyTypes: Self.layout.historyTypes, nextNLayer: nil, nextNTypes: nil,
                convolutionShape: [1, 12, 4], recurrentShape: [1, 2, 2, 2], paged: true)
            let writer = try Self.openDisk(root, layout: plain)
            Self.persist(writer, prompt: prompt, Self.synthetic(frontier: 32, seed: 5, layout: plain))
            #expect(writer.tier.drain(timeoutSeconds: 20))
            writer.tier.close()
            let reader = try Self.openDisk(root)
            let scope = reader.scope(chunk: Self.chunk)
            #expect(reader.boundaries(scope: scope, prompt: prompt, candidates: [8, 16, 24, 32]) == [32])
            #expect(reader.read(boundary: 32, prompt: prompt, scope: scope, stop: { false }) == nil)
            #expect(reader.tier.recordCount == 0 && reader.boundaries(scope: scope, prompt: prompt, candidates: [32]).isEmpty)

            // Other KDA heads (another rank's shard geometry) are refused too.
            Self.persist(reader, prompt: prompt, Self.synthetic(frontier: 32, seed: 6))
            #expect(reader.tier.drain(timeoutSeconds: 20))
            let state = try #require(try reader.tier.restore(scope: scope, tokens: prompt, frontier: 32, check: {}))
            let heads = Record.Layout(firstLayer: 0, dsaLayers: [3, 7], kdaLayers: [0, 1, 2, 4, 5, 6], latentWidth: 8,
                keyWidth: 4, historyTypes: Self.layout.historyTypes, nextNLayer: 8, nextNTypes: Self.layout.nextNTypes,
                convolutionShape: [1, 24, 4], recurrentShape: [1, 4, 2, 2], paged: true)
            #expect(throws: (any Error).self) { try Record.Restorable(state, layout: heads) }
            #expect(throws: (any Error).self) { try Record.Restorable(state, layout: plain) }
            #expect((try? Record.Restorable(state, layout: Self.layout)) != nil)

            // A changed byte: the read fails, the tier deletes the record.
            let name = try #require(try FileManager.default.contentsOfDirectory(atPath: reader.tier.directory.path)
                .first { $0.hasSuffix(".dbpx") })
            let url = reader.tier.directory.appendingPathComponent(name)
            var bytes = try Data(contentsOf: url)
            bytes[bytes.count - 9] ^= 0x10
            try bytes.write(to: url)
            #expect(reader.read(boundary: 32, prompt: prompt, scope: scope, stop: { false }) == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path) && reader.tier.recordCount == 0)
        }
    }

    /// Without SSD records the vote is the memory-only vote word for word; a
    /// boundary one rank holds only on its SSD tier counts, and marks the
    /// agreement as needing the confirmation.
    @Test func theVoteCountsBothTiersAndKeepsTheMemoryVote() {
        let candidates = [4096, 8192, 12_288]
        func votes(_ ranks: [[(memory: Bool, disk: Bool)]]) -> [Float] {
            (0 ..< candidates.count).map { index in
                ranks.reduce(0) { $0 + Vote.offer(inMemory: $1[index].memory, onDisk: $1[index].disk) }
            }
        }
        #expect(Vote.offer(inMemory: true, onDisk: true) == 1 && Vote.offer(inMemory: false, onDisk: false) == 0)
        let none = (memory: false, disk: false), memory = (memory: true, disk: false), disk = (memory: false, disk: true)
        // Memory only: the deepest boundary both hold, no confirmation.
        let both = votes([[memory, memory, memory], [memory, memory, none]])
        #expect(both == [2, 2, 1])
        #expect(Vote.agreed(sums: both, candidates: candidates).map { [$0.boundary, $0.ssd ? 1 : 0] } == [8192, 0])
        // One rank holds the deepest only on SSD: it is chosen, with the confirmation.
        let mixed = votes([[memory, memory, memory], [memory, memory, disk]])
        #expect(Vote.agreed(sums: mixed, candidates: candidates).map { [$0.boundary, $0.ssd ? 1 : 0] } == [12_288, 1])
        let ssd = votes([[none, none, disk], [none, none, disk]])
        #expect(Vote.agreed(sums: ssd, candidates: candidates).map { [$0.boundary, $0.ssd ? 1 : 0] } == [12_288, 1])
        // One rank alone, from either tier: not chosen.
        #expect(Vote.agreed(sums: votes([[memory, none, disk], [none, none, none]]), candidates: candidates) == nil)
        #expect(Vote.agreed(sums: votes([[memory, memory, disk], [memory, none, none]]), candidates: candidates)?.boundary
            == 4096)
        // Every memory-only holding decides as the vote before the SSD tier: the
        // deepest candidate whose 0/1 votes sum to two.
        for a in 0 ..< 8 {
            for b in 0 ..< 8 {
                let sums = (0 ..< 3).map { Float((a >> $0) & 1 + (b >> $0) & 1) }
                let old = sums.indices.filter { sums[$0] >= 2 }.last.map { candidates[$0] }
                #expect(Vote.agreed(sums: sums, candidates: candidates)?.boundary == old)
                #expect(Vote.agreed(sums: sums, candidates: candidates)?.ssd != true)
            }
        }
    }

    /// Two ranks, each with its own memory holdings and SSD tier under one
    /// root, run `openRequest`'s prefix plan with the sealed sums as plain
    /// sums: vote, then for an SSD agreement each rank's own take (memory
    /// first, else its record, checked) and the confirmation. A boundary one
    /// rank lacks is never chosen; a record one rank cannot read after the
    /// vote makes both prefill from zero, and is not offered again.
    @Test func bothRanksRestoreTheBoundaryOrNeither() throws {
        try Device.withDefaultDevice(.cpu) {
            let root = try glmRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let prompt = (0 ..< 45).map { 2 + ($0 * 13) % 31 }
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: Self.chunk)
            let epoch = UUID()
            let disks = try (0 ... 1).map { try Self.openDisk(root, rank: $0, epoch: epoch) }
            /// The plan: the agreed boundary, whether it needed the
            /// confirmation, and whether both ranks restore it.
            func plan(memory: [Set<Int>]) -> (boundary: Int, ssd: Bool, restored: Bool)? {
                let offers = (0 ... 1).map { rank in
                    let onDisk = disks[rank].boundaries(scope: disks[rank].scope(chunk: Self.chunk), prompt: prompt,
                        candidates: candidates)
                    return candidates.map { Vote.offer(inMemory: memory[rank].contains($0), onDisk: onDisk.contains($0)) }
                }
                guard let agreed = Vote.agreed(sums: zip(offers[0], offers[1]).map { $0 + $1 }, candidates: candidates)
                else { return nil }
                guard agreed.ssd else { return (agreed.boundary, false, true) }
                let local = (0 ... 1).map { rank in
                    memory[rank].contains(agreed.boundary) || disks[rank].read(boundary: agreed.boundary, prompt: prompt,
                        scope: disks[rank].scope(chunk: Self.chunk), stop: { false }) != nil
                }
                return (agreed.boundary, true, local.allSatisfy { $0 })
            }
            // Rank 0 alone wrote a record: nothing is agreed, nothing is read.
            Self.persist(disks[0], prompt: prompt, Self.synthetic(frontier: 40, seed: 7))
            #expect(disks[0].tier.drain(timeoutSeconds: 20))
            #expect(plan(memory: [[], []]) == nil)
            #expect(disks[0].tier.stats.restores == 0)
            // Both wrote theirs: both restore from SSD, after the confirmation.
            Self.persist(disks[1], prompt: prompt, Self.synthetic(frontier: 40, seed: 8))
            #expect(disks[1].tier.drain(timeoutSeconds: 20))
            #expect(plan(memory: [[], []]).map { [$0.boundary, $0.ssd ? 1 : 0, $0.restored ? 1 : 0] } == [40, 1, 1])
            // One in memory, one on SSD: still confirmed; both in memory: no confirmation.
            #expect(plan(memory: [[40], []]).map { [$0.boundary, $0.ssd ? 1 : 0, $0.restored ? 1 : 0] } == [40, 1, 1])
            #expect(plan(memory: [[32, 40], [32, 40]]).map { [$0.boundary, $0.ssd ? 1 : 0] } == [40, 0])
            // A shallower boundary in both memories loses to a deeper one on SSD.
            #expect(plan(memory: [[32], [32]]).map { [$0.boundary, $0.ssd ? 1 : 0, $0.restored ? 1 : 0] } == [40, 1, 1])
            // Rank 1's record becomes unreadable after it was offered: both
            // prefill from zero, and the record is gone from the next vote.
            let name = try #require(try FileManager.default.contentsOfDirectory(atPath: disks[1].tier.directory.path)
                .first { $0.hasSuffix(".dbpx") })
            let url = disks[1].tier.directory.appendingPathComponent(name)
            var bytes = try Data(contentsOf: url)
            bytes[bytes.count / 2] ^= 0x01
            try bytes.write(to: url)
            #expect(plan(memory: [[], []]).map { [$0.boundary, $0.ssd ? 1 : 0, $0.restored ? 1 : 0] } == [40, 1, 0])
            #expect(plan(memory: [[], []]) == nil)
            #expect(disks[0].tier.recordCount == 1 && disks[1].tier.recordCount == 0)
            // A rank whose request stops while it reads declines too; its record stays.
            #expect(disks[0].read(boundary: 40, prompt: prompt, scope: disks[0].scope(chunk: Self.chunk),
                stop: { true }) == nil)
            #expect(disks[0].tier.recordCount == 1)
            for disk in disks { disk.tier.close() }
        }
    }
}
