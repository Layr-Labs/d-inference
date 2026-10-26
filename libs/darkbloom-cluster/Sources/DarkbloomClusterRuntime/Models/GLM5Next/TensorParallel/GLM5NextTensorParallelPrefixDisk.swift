import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The SSD tier of a GLM tensor-parallel rank's prompt-prefix cache
/// (`GLM5NextTensorParallelPrefixCache` is its memory tier), in the encrypted
/// records of `QwenStagePrefixDiskTier`. Each rank keeps only its own state at
/// a prompt's kept boundary: its heads' KDA state, its copy of the replicated
/// DSA histories and the NextN history (`GLM5NextTensorParallelPrefixRecord`).
/// The DSA latents are stored at the pair's checkpoint precision
/// (`encoding(_:layout:)`, balanced by default): a record's older latent rows
/// restore approximate, its newest 128 and everything else exact.
///
/// A record is written behind serving, after the request retired cleanly, and
/// only for a boundary the memory tier holds; it is read from that entry's
/// pages, which it shares until it is written. The record scope outlives the
/// owner process (`planScope`), so a restarted pair finds what the last one
/// kept. A record is only an offer: the sealed vote counts it
/// (`QwenTensorParallelPrefixCache.agree`), and a boundary taken from an SSD
/// record on either rank is restored only after a second sealed exchange
/// shows both ranks have it (`QwenTensorParallelPrefixCache.confirm`), both
/// ranks or neither.
struct GLM5NextTensorParallelPrefixDisk {
    let tier: QwenStagePrefixDiskTier
    /// The persistent part of every request scope on this rank.
    let planScope: String
    /// What a record holds on this rank, and must hold to adopt into it.
    let layout: GLM5NextTensorParallelPrefixRecord.Layout

    /// What names a directory of records: everything a restored state's bytes
    /// depend on, from what each rank knows at load: the plan and shares, the
    /// verified artifact and inventory, both ranks' builds (which fix the
    /// arithmetic) and the NextN policy. Never the membership epoch, nor the
    /// cut the leader installed: every rank holds every layer, so tensor
    /// parallel computes the same bits at any cut. The one place a request's
    /// prefix scope on disk is derived from (with `scope(chunk:)`).
    static func planScope(artifactAggregateSHA256: String, inventorySHA256: String, rankBuildSHA256: [String],
                          mtpDepth: Int) -> String {
        typealias Runtime = GLM5NextTensorParallelResidentRuntime
        return QwenStagePrefixDiskTier.planScope(
            planFingerprint: [Runtime.planName, "shares=1:1", Runtime.partialsTransport].joined(separator: "|"),
            artifactAggregateSHA256: artifactAggregateSHA256, storageCommitmentSHA256: inventorySHA256,
            rankBuildSHA256: rankBuildSHA256, generationMode: ClusterGenerationMode.tensorParallel.rawValue,
            prefillSchedule: "serial|glm5-next-tp-prefix-v2|nextn=" + (mtpDepth > 0 ? "depth-\(mtpDepth)" : "none"))
    }

    /// A request's scope on disk: the plan scope, the prompt grid its
    /// boundaries lie on, and how this rank keeps its histories.
    func scope(chunk: Int) -> String {
        planScope + "|chunk=\(chunk)|kv=" + (layout.paged ? "paged" : "contiguous")
    }

    /// Opens this rank's tier, or nil when it is off or unusable (the rank
    /// then keeps prefixes in memory only). `encoding` is the one the load
    /// bound into its agreement (`QwenStagePrefixDiskEncoding.fromEnvironment`
    /// for `.glm5NextDSA`); the tier applies it as `encoding(_:layout:)` says.
    static func open(configuration: QwenStagePrefixDiskConfiguration, planScope: String, rank: Int,
                     encoding: QwenStagePrefixDiskEncoding = .native, stagingEpoch: String, stage: GLM5NextTextStage,
                     mtp: GLM5NextMTP?) -> Self? {
        let layout: GLM5NextTensorParallelPrefixRecord.Layout
        do { layout = try .init(stage: stage, mtp: mtp) } catch {
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=unavailable error=\(qwenPrefixLogWord(error))")
            return nil
        }
        return QwenStagePrefixDiskTier.open(configuration: configuration, planScope: planScope, rank: rank,
            encoding: Self.encoding(encoding, layout: layout), stagingEpoch: stagingEpoch)
            .map { Self(tier: $0, planScope: planScope, layout: layout) }
    }

    /// How a rank of `layout` stores its records under `records`: each DSA
    /// layer's latents encoded (the family's `keys` slot), its index keys and
    /// pool gates native, and the NextN history, kept as an attention entry
    /// under its own layer, native as all speculative state is.
    static func encoding(_ records: QwenStagePrefixDiskEncoding,
                         layout: GLM5NextTensorParallelPrefixRecord.Layout) -> QwenStagePrefixDiskEncoding {
        records.keepingNative(layers: layout.nextNLayer.map { [$0] } ?? [])
    }

    /// The candidates this rank holds as complete, live records.
    func boundaries(scope: String, prompt: [Int], candidates: [Int]) -> Set<Int> {
        guard let deepest = candidates.last else { return [] }
        return Set(tier.frontiers(scope: scope, tokens: prompt, maximumFrontier: deepest)).intersection(candidates)
    }

    /// This rank's record of `boundary`, read and checked to adopt into its
    /// request state before anything is written; nil when this rank cannot
    /// restore it: no record, one that cannot be read or authenticated (the
    /// tier deletes it), one that does not adopt (deleted here), or a request
    /// that stopped while it was read (the record is kept). Either way the
    /// confirmation that follows decides for both ranks.
    func read(boundary: Int, prompt: [Int], scope: String, stop: () -> Bool)
        -> GLM5NextTensorParallelPrefixRecord.Restorable? {
        struct Stopped: Error {}
        let state: QwenStagePrefixState?
        do { state = try tier.restore(scope: scope, tokens: prompt, frontier: boundary, check: { if stop() { throw Stopped() } }) }
        catch { return nil }
        guard let state else { return nil }
        do { return try .init(state, layout: layout) } catch {
            log("darkbloom-prefix-ssd-v1 rank=\(tier.rank) event=restore-rejected frontier=\(boundary)"
                + " reason=not_adoptable error=\(qwenPrefixLogWord(error))")
            tier.forget(scope: scope, tokens: prompt, frontier: boundary)
            return nil
        }
    }
}

/// One GLM tensor-parallel rank's prompt state at a boundary in the SSD
/// tier's record shape (`QwenStagePrefixState`), the GLM pipeline's mapping
/// (`GLM5NextStagePrefixSnapshot`): each DSA layer's latents are an attention
/// entry's `keys` and its index keys and pool gates, side by side, its
/// `values`, each `[1, 1, F, width]` (one head); the NextN history is kept the
/// same way under the NextN layer's own index (`hiddenLayers`, the
/// checkpoint's `layers.<hiddenLayers>`); each KDA layer's convolution and
/// recurrent state (this rank's heads) are its `recurrent` pair. A committed
/// prompt prefix is valid at every position, so validity is not stored and
/// a restore writes it whole. Keys are the model's global layer indices.
enum GLM5NextTensorParallelPrefixRecord {
    /// What a record holds on one rank, and must hold to adopt into it.
    struct Layout {
        /// The stage's first global layer (its cache's layer 0) and its layers by kind.
        let firstLayer: Int
        let dsaLayers: [Int]
        let kdaLayers: [Int]
        /// Widths and element types of a DSA history's latents, index keys
        /// and pool gates (the page pool's), and of the NextN history's.
        let latentWidth: Int
        let keyWidth: Int
        let historyTypes: [DType]
        /// The NextN history's index and element types, when the rank speculates.
        let nextNLayer: Int?
        let nextNTypes: [DType]?
        /// This rank's KDA convolution `[1, 3 * heads * headDim, kernel]` and
        /// recurrent state `[1, heads, headDim, headDim]` (its heads).
        let convolutionShape: [Int]
        let recurrentShape: [Int]
        /// Histories live in pages (`GLM5NextTensorParallelPagedKV.swift`).
        let paged: Bool
    }

    typealias Rows = (keys: QwenStagePrefixDiskRows, values: QwenStagePrefixDiskRows)

    /// The record of `cache` (and the NextN history `history`) at `frontier`
    /// for the SSD tier's writer: the KDA states as they are (the job holds
    /// them), and readers of the DSA and NextN histories' rows, which hold
    /// their pages (or arrays) as a copy does until the record is written:
    /// nothing is gathered or copied here. Throws when the state is not
    /// storable whole: another frontier, or no NextN history where the rank
    /// speculates (a restore without it would propose differently).
    static func capture(cache: GLM5NextTextStageCache, history: GLM5NextMTPCheckpoint?, layout: Layout,
                        frontier: Int) throws -> (state: QwenStagePrefixState, rows: [Int: Rows]) {
        guard frontier > 0, cache.layers.count == layout.dsaLayers.count + layout.kdaLayers.count else {
            throw ProbeError("GLM prefix record differs from the stage's layers")
        }
        var rows: [Int: Rows] = [:], recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for (position, layer) in cache.layers.enumerated() {
            let index = layout.firstLayer + position
            guard layer.offset == frontier else { throw ProbeError("GLM prefix record frontier differs from a layer's") }
            if let dsa = layer as? GLM5NextDSACache, let read = dsa.historyRows() {
                rows[index] = try Self.rows(read, widths: [layout.latentWidth, layout.keyWidth], types: layout.historyTypes)
            } else if let kda = layer as? GLM5NextKDACache, case let state = kda.state, state.count == 2 {
                recurrent[index] = (conv: state[0], ssm: state[1])
            } else {
                throw ProbeError("GLM prefix record lacks layer \(index)")
            }
        }
        if let nextN = layout.nextNLayer, let types = layout.nextNTypes {
            guard let history, !history.hasRecycledHidden, history.inputCount == frontier,
                  let read = history.historyRows() else {
                throw ProbeError("GLM prefix record lacks the NextN history at its boundary")
            }
            rows[nextN] = try Self.rows(read, widths: [layout.latentWidth, layout.keyWidth], types: types)
        }
        return (QwenStagePrefixState(committedTokens: frontier, attention: [:], recurrent: recurrent), rows)
    }

    /// A history's latents (`keys`) and its index keys and pool gates side by
    /// side (`values`), read row by row from `read` (each unit's rows must be
    /// valid: a committed prompt prefix is).
    private static func rows(_ read: GLM5NextDSAHistoryRows, widths: [Int], types: [DType]) throws -> Rows {
        guard read.widths.prefix(3).elementsEqual([widths[0], widths[1], widths[1]]),
              read.types.prefix(3).elementsEqual(types), read.types[3] == .bool else {
            throw ProbeError("GLM prefix record history differs from the stage's geometry")
        }
        let latent = read.rowBytes(0), key = read.rowBytes(1), packed = 2 * key
        let keys = QwenStagePrefixDiskRows(dtype: types[0], tokens: read.count, width: widths[0],
            heldBytes: read.heldBytes, read: { rows, destination in
                try read.copy(plane: 0, rows: rows, to: destination, stride: latent)
            })
        let values = QwenStagePrefixDiskRows(dtype: types[1], tokens: read.count, width: 2 * widths[1],
            heldBytes: 0, read: { rows, destination in
                try read.copy(plane: 1, rows: rows, to: destination, stride: packed)
                try read.copy(plane: 2, rows: rows, to: destination.advanced(by: key), stride: packed)
                var validity = [UInt8](repeating: 0, count: rows.count)
                try validity.withUnsafeMutableBytes { try read.copy(plane: 3, rows: rows, to: $0.baseAddress!, stride: 1) }
                guard !validity.contains(0) else { throw ProbeError("GLM prefix record history holds an invalid row") }
            })
        return (keys, values)
    }

    /// A record read from this rank's SSD tier, checked to adopt into a
    /// request state of `layout` before anything is written: every layer of
    /// the stage present with this rank's shapes and element types, the NextN
    /// history exactly when the rank speculates, nothing else.
    struct Restorable {
        let frontier: Int
        /// Per DSA layer: `[latents, index keys, pool gates, validity]` `[1, F, ...]`.
        let histories: [Int: [MLXArray]]
        let states: [Int: (conv: MLXArray, ssm: MLXArray)]
        let nextN: [MLXArray]?

        init(_ state: QwenStagePrefixState, layout: Layout) throws {
            let f = state.committedTokens
            let attention = layout.dsaLayers + (layout.nextNLayer.map { [$0] } ?? [])
            guard f > 0, state.speculativeHistory == nil, Set(state.attention.keys) == Set(attention),
                  Set(state.recurrent.keys) == Set(layout.kdaLayers) else {
                throw ProbeError("GLM prefix record holds other layers than this rank's")
            }
            func history(_ index: Int, types: [DType]) throws -> [MLXArray] {
                let pair = state.attention[index]!
                guard pair.keys.shape == [1, 1, f, layout.latentWidth], pair.keys.dtype == types[0],
                      pair.values.shape == [1, 1, f, 2 * layout.keyWidth], pair.values.dtype == types[1] else {
                    throw ProbeError("GLM prefix record history \(index) differs from this rank's")
                }
                let packed = pair.values.reshaped(1, f, 2 * layout.keyWidth)
                return [pair.keys.reshaped(1, f, layout.latentWidth), packed[0..., 0..., ..<layout.keyWidth],
                        packed[0..., 0..., layout.keyWidth...], MLXArray.ones([1, f], dtype: .bool)]
            }
            frontier = f
            histories = try Dictionary(uniqueKeysWithValues: layout.dsaLayers.map {
                ($0, try history($0, types: layout.historyTypes))
            })
            nextN = try layout.nextNLayer.map { try history($0, types: layout.nextNTypes!) }
            for pair in state.recurrent.values {
                guard pair.conv.shape == layout.convolutionShape, pair.conv.dtype.isFloatingPoint,
                      pair.ssm.shape == layout.recurrentShape, pair.ssm.dtype == .float32 else {
                    throw ProbeError("GLM prefix record KDA state differs from this rank's heads")
                }
            }
            states = state.recurrent
        }

        /// Writes it into `cache` (fresh: a paged history's rows go into new
        /// pages counted against the cache's account) and the NextN history
        /// into `speculation`: the same bits a prefill to the boundary leaves,
        /// evaluated, so the record's buffers can go.
        func write(into cache: GLM5NextTextStageCache, layout: Layout,
                   speculation: GLM5NextTensorParallelSpeculation?) throws {
            guard cache.offset == 0, (speculation != nil) == (nextN != nil) else {
                throw ProbeError("GLM prefix restore needs a fresh request state")
            }
            for (position, layer) in cache.layers.enumerated() {
                let index = layout.firstLayer + position
                if let dsa = layer as? GLM5NextDSACache, let rows = histories[index] {
                    try dsa.restoreRows(rows)
                } else if let kda = layer as? GLM5NextKDACache, let state = states[index] {
                    kda.state = [state.conv, state.ssm]
                    kda.metaState = ["glm5_kda_v1", String(frontier)]
                } else {
                    throw ProbeError("GLM prefix restore lacks layer \(index)")
                }
            }
            if let nextN, let speculation { try speculation.restore(history: nextN) }
            eval(cache.layers.flatMap { $0.innerState() } + (try speculation?.evaluationTargets() ?? []))
            guard cache.offset == frontier else { throw ProbeError("GLM prefix restore left another frontier") }
        }
    }
}

extension GLM5NextTensorParallelPrefixRecord.Layout {
    /// The layout of `stage` on this rank (its shard's KDA heads), with the
    /// NextN history of `mtp` when it speculates.
    init(stage: GLM5NextTextStage, mtp: GLM5NextMTP?) throws {
        let c = stage.plan.configuration
        let linear = try (stage.plan.shard?.localConfiguration(c) ?? c).linearAttention
        // A contiguous history is appended with the types a page pool takes.
        let pool = try stage.dsaPagePool ?? stage.makeDSAPagePool()
        let nextN = try mtp?.historyTypes()
        self.init(firstLayer: stage.plan.layers.lowerBound,
            dsaLayers: stage.plan.layers.filter { c.layerTypes[$0] == .deepseekSparseAttention },
            kdaLayers: stage.plan.layers.filter { c.layerTypes[$0] == .linearAttention },
            latentWidth: c.kvLoraRank, keyWidth: c.indexHeadDim,
            historyTypes: [pool.latentType, pool.keyType, pool.gateType],
            nextNLayer: mtp == nil ? nil : c.hiddenLayers, nextNTypes: nextN.map { [$0.latents, $0.keys, $0.gates] },
            convolutionShape: [1, 3 * linear.numHeads * linear.headDim, linear.shortConvKernelSize],
            recurrentShape: [1, linear.numHeads, linear.headDim, linear.headDim], paged: stage.dsaPagePool != nil)
        guard historyTypes[1] == historyTypes[2], nextNTypes.map({ $0[1] == $0[2] }) ?? true else {
            throw ProbeError("GLM prefix records keep index keys and pool gates of one type")
        }
    }
}

extension GLM5NextTensorParallelResidentRuntime {
    /// A boundary both ranks offered, at least one only from its SSD tier
    /// (`QwenTensorParallelPrefixCache.agreed`): this rank takes it from its
    /// memory tier when it holds it there, else reads its record (checked
    /// before anything is written), and a second sealed exchange confirms that
    /// both ranks have it. Only then is the request's state written: a copy
    /// of the memory entry (as a memory hit), or the record's rows in fresh
    /// pages of the request's account, which the memory tier then keeps too,
    /// so the next offer finds the boundary in memory. Otherwise (either rank
    /// could not) both prefill from zero. Returns the restored cache, or nil.
    func restoreAgreedFromEitherTier(_ boundary: Int, prompt: [Int], scope: String, diskScope: String?,
                                     stage: GLM5NextTextStage, pages: GLM5NextPageReservation?,
                                     speculation: GLM5NextTensorParallelSpeculation?,
                                     stop: () -> Bool) throws -> GLM5NextTextStageCache? {
        let rank = collective.rank
        let memory = prefix.restore(scope: scope, prompt: prompt, length: boundary)
        var record: GLM5NextTensorParallelPrefixRecord.Restorable?
        if let disk = prefixDisk, let diskScope {
            if memory != nil { disk.tier.touch(scope: diskScope, tokens: prompt, frontier: boundary) }
            else { record = disk.read(boundary: boundary, prompt: prompt, scope: diskScope, stop: stop) }
        }
        let local = memory != nil || record != nil, tier = memory != nil ? "resident" : "ssd"
        guard try QwenTensorParallelPrefixCache.confirm(local, group: group) else {
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-declined frontier=\(boundary) tier=\(tier)"
                + " local=\(local ? 1 : 0) kept=0")
            return nil
        }
        if let memory {
            // The entry's pages are shared; what the request appends is its own.
            memory.cache.bindPages(to: pages?.account)
            try speculation?.restore(memory.mtp)
            return memory.cache
        }
        guard let record, let disk = prefixDisk else { throw ProbeError("GLM prefix confirmed without a state") }
        let cache = stage.newCache(account: pages?.account)
        try record.write(into: cache, layout: disk.layout, speculation: speculation)
        let kept = prefix.store(scope: scope, prompt: prompt, length: boundary, cache: cache,
            mtp: try speculation?.checkpoint())
        log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-confirmed frontier=\(boundary) prompt=\(prompt.count)"
            + " kept=\(kept ? 1 : 0)")
        return cache
    }

    /// After a request retired cleanly: its kept boundary, as the memory tier
    /// holds it, goes to this rank's SSD tier behind serving (read from the
    /// entry's pages on the writer; an existing record is only touched).
    /// Nothing when the tier is off or the memory tier no longer holds it.
    func persistPrefix(_ prompt: [Int], opened: OpenedRequest, boundary: Int) {
        guard let disk = prefixDisk, let scope = opened.prefixScope, let diskScope = opened.prefixDiskScope,
              let entry = prefix.entry(scope: scope, prompt: prompt, length: boundary) else {
            return
        }
        let chunk = opened.chunk
        do {
            let record = try GLM5NextTensorParallelPrefixRecord.capture(cache: entry.cache, history: entry.mtp,
                layout: disk.layout, frontier: boundary)
            disk.tier.persist(scope: diskScope, tokens: prompt, states: [record.state], blockTokens: chunk,
                attentionRows: record.rows)
        } catch {
            log("darkbloom-prefix-ssd-v1 rank=\(collective.rank) event=persist-dropped reason=unstorable prompt=\(boundary)"
                + " error=\(qwenPrefixLogWord(error))")
        }
    }
}
