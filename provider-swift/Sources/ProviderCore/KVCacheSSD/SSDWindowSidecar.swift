// Copyright © 2026 Eigen Labs.
//
// WS-4.2 — the windowed sidecar: sliding-window K/V persisted ALONGSIDE the
// existing full-attention DBK3 blocks, so an adopter can RESTORE a donor's
// sliding window instead of replaying it.
//
// Why this exists
// ---------------
// A cache hit restores the 5 full-attention layers of gemma-4 exactly, but
// its 25 sliding rows start EMPTY at the matched boundary. Their hidden
// states feed the downstream full layers, whose K/V writes persist and change
// later logits — so the engine must replay `windowCount × maxWindow` = 25,600
// tokens before the row is bit-exact (`2026-07-19-frozen-full-prefix-cache-
// proof.md`). Against gemma-4's p50 prompt of 979 tokens the resulting
// donation floor of 27,137 makes 2.3% of its traffic donatable.
//
// Persist the window and the replay disappears.
//
// Format
// ------
// A sidecar is an ORDINARY DBK3 FILE — same magic, same format version 3,
// same per-file IV, same wrapped-DEK/KEK scheme, same canonical-JSON AAD,
// same `<root>/<tagHex[0..2]>/<tagHex>.dbk3` pathname grammar. It differs in
// exactly two ways:
//
//   1. its 128-bit filename tag comes from a SEPARATE HMAC domain
//      (`SSDLookupKeys.windowTag`), so a block and its sidecar never collide
//      and a disk observer cannot correlate the pair without K_lookup;
//   2. its authenticated metadata carries `windowKind` / `windowBase` /
//      `windowTokens`, and its chunks are the SLIDING layers' K/V rather than
//      the full layers'.
//
// Everything downstream is therefore inherited verbatim: the RAM index, the
// sliding TTL, box-wide LRU eviction, the startup directory scan (the
// recovery protocol), the temp sweep, the write-behind pipeline, and the
// low-disk / endurance guards. A sidecar that is evicted or fails to
// authenticate simply is not there, and the adopter falls back to replay.
//
// Granularity: ONE SIDECAR PER BLOCK, not per window
// --------------------------------------------------
// A sidecar holds one 256-token block's worth of sliding K/V. The window at
// boundary M is assembled from the `W / blockSize` sidecars that tile
// [M − W, M) — "read-terminal-four" for gemma-4.
//
// Per-block beats one-file-per-window for two independent reasons:
//
//   * Dedupe. Sidecars are content-addressed off the same chain hash as the
//     block, so a token's sliding K/V is stored ONCE across every donation
//     that shares the prefix. Window-sized files written at successive turn
//     boundaries would duplicate up to `W − Δ` tokens per turn.
//   * Coverage. A donating row's ring holds exactly the last W positions
//     ending at its own `absoluteOffset`, which is NOT block-aligned (the
//     request stopped mid-block). One donation can therefore only ever cover
//     `floor(W/blockSize) − 1` whole blocks — three of gemma-4's four. But
//     successive donations end at different offsets and their covered ranges
//     TILE: a donation at offset o covers blocks
//     `[ceil((o−W)/blockSize), floor(o/blockSize))`, so two donations
//     straddling a boundary between them supply all four blocks it needs.
//     A window-granular file can never be assembled from two donors.
//
// `coveredBlocks` below is that arithmetic, and it is the load-bearing
// correctness rule of this file: a PARTIAL window restore is NOT exact (the
// missing oldest entries are invisible to attention and cannot be recovered
// by a short replay — recovering them is the full `windowCount × maxWindow`
// problem again), so a boundary is adoptable only when EVERY tiling block is
// present.

import Foundation
import MLX
import MLXLMCommon

// MARK: - Geometry

/// The sliding-layer shape a model's sidecars must carry, derived once from
/// the same `[CBv2LayerKind]` that produces the layout epoch.
struct SSDWindowSidecarGeometry: Sendable, Equatable {

    /// One storage-owning sliding-window layer.
    struct Layer: Sendable, Equatable {
        let index: Int
        let kvHeads: Int
        let headDim: Int
    }

    /// The model's largest sliding window, in tokens (`W`).
    let windowTokens: Int
    let blockSize: Int
    /// `W / blockSize` — how many sidecars tile one window ("terminal four").
    let blocksPerWindow: Int
    /// Storage-owning sliding layers, ascending by model layer index.
    let layers: [Layer]
    /// Total model layer slots, so a rebuild can produce a full-width array
    /// without the model (mirrors `SSDBlockMetadata.layerCount`).
    let layerCount: Int

    /// Derive the sidecar geometry, or nil when this model cannot have one.
    ///
    /// Fail-closed cases, each of which would otherwise produce a silently
    /// inexact restore:
    ///
    ///  * no sliding layers ⇒ nothing to persist (replay bound is already 0);
    ///  * MIXED window sizes ⇒ one payload cannot serve two windows;
    ///  * `W < blockSize` or `W % blockSize != 0` ⇒ the window does not tile
    ///    into whole blocks, and a donating ring never holds a whole block
    ///    beyond its window (gpt-oss-20b's `W = 128` lands here and keeps its
    ///    1,536-token replay bound);
    ///  * a KV-shared sliding layer ⇒ it borrows storage from its source, so
    ///    persisting it would double-write; the source layer is persisted and
    ///    the borrow is re-established by the engine, exactly as
    ///    `SSDPrefixCache.isCacheable` treats shared FULL layers.
    static func derive(
        layerKinds: [CBv2LayerKind], blockSize: Int
    ) -> SSDWindowSidecarGeometry? {
        guard blockSize > 0, !layerKinds.isEmpty else { return nil }
        var window = 0
        var layers: [Layer] = []
        for (index, kind) in layerKinds.enumerated() {
            guard case .slidingWindow(let w) = kind.attention else { continue }
            guard w > 0 else { return nil }
            if window == 0 {
                window = w
            } else if window != w {
                return nil  // mixed windows: one payload cannot serve both
            }
            guard kind.sharesKVWithLayer == nil else { continue }
            guard kind.kvHeads > 0, kind.headDim > 0 else { return nil }
            layers.append(Layer(index: index, kvHeads: kind.kvHeads, headDim: kind.headDim))
        }
        guard window >= blockSize, window % blockSize == 0, !layers.isEmpty else { return nil }
        return SSDWindowSidecarGeometry(
            windowTokens: window,
            blockSize: blockSize,
            blocksPerWindow: window / blockSize,
            layers: layers,
            layerCount: layerKinds.count)
    }

    /// Plaintext bytes one sidecar carries, for a given element width.
    func bytesPerBlock(elementSize: Int) -> Int {
        var total = 0
        for layer in layers {
            total += 2 * layer.kvHeads * blockSize * layer.headDim * elementSize
        }
        return total
    }

    /// Block indices whose ENTIRE token span lies inside the donated window
    /// `[base, base + tokens)`, clamped to `[0, blockCount)`.
    ///
    /// This is the whole coverage rule. A donating row retains exactly the
    /// last `W` positions ending at its own absolute offset, so `base` is
    /// almost never block-aligned and the leading partial block is dropped.
    ///
    /// The `blocksPerWindow` clamp is a BOUNDS GUARD, not arithmetic tidiness,
    /// and it is deliberately not delegated to the caller. The only production
    /// caller passes `span()`'s output, which already refuses
    /// `tokens > windowTokens`, so the clamp does not fire today — but the
    /// range returned here is fed straight to
    /// `SSDWindowSidecar.extract(blockIndex:…)`, which slices
    /// `window.keys[…, start ..< start + blockSize, …]`. A range wider than
    /// the window makes that slice run off the end of a live MLXArray inside
    /// the hardened inference process. `extract` re-checks
    /// (`end <= window.keys.dim(2)`), so today the failure would be a silently
    /// dropped sidecar rather than a bad read — two independent guards, which
    /// is the correct number for this one.
    func coveredBlocks(base: Int, tokens: Int, blockCount: Int) -> Range<Int> {
        guard base >= 0, tokens > 0, blockCount > 0 else { return 0 ..< 0 }
        // First whole block at or after `base`.
        let first = (base + blockSize - 1) / blockSize
        // Last whole block ending at or before `base + tokens`.
        let end = (base + tokens) / blockSize
        let lower = max(0, first)
        let upper = min(blockCount, end)
        guard lower < upper else { return 0 ..< 0 }
        // A window can never tile more blocks than it spans.
        let capped = max(lower, upper - blocksPerWindow)
        return capped ..< upper
    }
}

// MARK: - Codec

/// Build and rebuild the sliding-layer payload of a windowed sidecar. The
/// crypto, the file layout, and the AAD discipline all belong to
/// `SSDBlockStore`; this type owns only the tensor↔chunk mapping and the
/// binding checks that make a spliced or mismatched sidecar fail closed.
enum SSDWindowSidecar {

    /// `SSDBlockMetadata.windowKind` of a v1 sliding-window sidecar.
    static let kind = "sliding-window-v1"

    /// One donor's sliding window: the ring contents of every storage-owning
    /// sliding layer plus the absolute position of the first retained token.
    /// Shape-compatible with WS-4.1's frozen
    /// `PagedSequenceKV.windowSnapshot() -> (keys:values:base:)?`.
    typealias Window = (keys: MLXArray, values: MLXArray, base: Int)

    /// The `(keys, values, base)` window that a `CBv2SequenceKV.snapshot()`
    /// triple describes. `snapshot()` reports the position of the NEXT token
    /// in temporal order, so the first retained entry sits at
    /// `offset − retained`.
    ///
    /// This is the ONE place that arithmetic lives: both donor paths — the
    /// state-based overload's `windowSnapshot()` and the engine's
    /// `CBv2SlidingWindowDonating` hand-off, which arrives already
    /// snapshotted on the engine thread — resolve through it, so they can
    /// never disagree about where a donated ring is anchored.
    static func window(
        fromSnapshot snapshot: (keys: MLXArray, values: MLXArray, offset: Int)?
    ) -> Window? {
        guard let snapshot, snapshot.keys.ndim == 4 else { return nil }
        let retained = snapshot.keys.dim(2)
        guard retained > 0, snapshot.offset >= retained else { return nil }
        return (keys: snapshot.keys, values: snapshot.values, base: snapshot.offset - retained)
    }

    /// Per-layer windows for a full-width engine sliding-snapshot array.
    /// Entries the engine left nil (full-attention and KV-shared layers)
    /// stay nil; `span` then rejects the set unless every storage-owning
    /// sliding layer produced one.
    static func windows(
        fromSnapshots snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?]
    ) -> [Window?] {
        snapshots.map { window(fromSnapshot: $0) }
    }

    /// Validate a per-layer window set against the geometry and collapse it to
    /// the single `(base, tokens)` span every layer must agree on.
    ///
    /// Every storage-owning sliding layer must be present, four-dimensional,
    /// shaped `[1, kvHeads, tokens, headDim]`, and anchored at the SAME base —
    /// rows advance in lockstep, so a disagreement means a caller bug or a
    /// mid-flight mutation, and either one would splice two positions'
    /// entries into one payload.
    static func span(
        windows: [Window?], geometry: SSDWindowSidecarGeometry
    ) -> (base: Int, tokens: Int)? {
        guard windows.count == geometry.layerCount else { return nil }
        var base = -1
        var tokens = -1
        for layer in geometry.layers {
            guard let window = windows[layer.index] else { return nil }
            guard window.base >= 0,
                window.keys.ndim == 4, window.values.ndim == 4,
                window.keys.dim(0) == 1, window.values.dim(0) == 1,
                window.keys.dim(1) == layer.kvHeads, window.values.dim(1) == layer.kvHeads,
                window.keys.dim(3) == layer.headDim, window.values.dim(3) == layer.headDim,
                window.keys.dim(2) == window.values.dim(2),
                window.keys.dim(2) > 0
            else { return nil }
            if base < 0 {
                base = window.base
                tokens = window.keys.dim(2)
            } else if base != window.base || tokens != window.keys.dim(2) {
                return nil
            }
        }
        guard base >= 0, tokens > 0, tokens <= geometry.windowTokens else { return nil }
        return (base, tokens)
    }

    /// Extract block `blockIndex`'s slice of the donated window into compact
    /// host buffers, in the same engine-native `[1, kvHeads, blockSize,
    /// headDim]` layout the full-attention blocks use.
    ///
    /// Returns nil when the block is not fully covered — callers get the
    /// covered set from `SSDWindowSidecarGeometry.coveredBlocks`, so a nil
    /// here is a programming error, not a policy outcome.
    static func extract(
        blockIndex: Int,
        windows: [Window?],
        geometry: SSDWindowSidecarGeometry,
        base: Int
    ) -> (chunks: [Data], descriptors: [SSDBlockChunkDescriptor], sizes: [Int])? {
        let start = blockIndex * geometry.blockSize - base
        guard start >= 0, windows.count == geometry.layerCount else { return nil }
        let end = start + geometry.blockSize
        var slices: [MLXArray] = []
        slices.reserveCapacity(geometry.layers.count * 2)
        for layer in geometry.layers {
            guard let window = windows[layer.index], end <= window.keys.dim(2) else { return nil }
            slices.append(window.keys[.ellipsis, start ..< end, 0...])
            slices.append(window.values[.ellipsis, start ..< end, 0...])
        }
        eval(slices)
        var chunks: [Data] = []
        var descriptors: [SSDBlockChunkDescriptor] = []
        var sizes: [Int] = []
        chunks.reserveCapacity(slices.count)
        descriptors.reserveCapacity(slices.count)
        sizes.reserveCapacity(slices.count)
        for (i, layer) in geometry.layers.enumerated() {
            for tensor in 0 ..< 2 {
                let data = slices[i * 2 + tensor].asData(access: .copy)
                chunks.append(data.data)
                sizes.append(data.data.count)
                descriptors.append(
                    SSDBlockChunkDescriptor(
                        layerIndex: layer.index, tensor: tensor,
                        shape: data.shape, dtype: String(describing: data.dType)))
            }
        }
        return (chunks, descriptors, sizes)
    }

    /// Authenticated-metadata binding check for ONE sidecar of a window run.
    ///
    /// `windowBaseTag` is the keyed commitment to the sidecar's absolute base
    /// (`SSDLookupKeys.windowBaseCommitment`) and it is in the GCM AAD, so
    /// this rejects a file that authenticates correctly but describes a
    /// different absolute position — the anti-splice guard that keeps a
    /// truncated-tag collision from silently restoring the wrong 256 tokens.
    /// The caller supplies the commitment it recomputed for the base it
    /// EXPECTS, so the position never has to appear in the header.
    static func isBound(
        _ metadata: SSDBlockMetadata,
        expectedBaseTag: String,
        geometry: SSDWindowSidecarGeometry
    ) -> Bool {
        metadata.windowKind == kind
            && metadata.windowBaseTag == expectedBaseTag
            && metadata.windowTokens == geometry.blockSize
            && metadata.blockSize == geometry.blockSize
            && metadata.layerCount == geometry.layerCount
            && metadata.chunks.count == geometry.layers.count * 2
    }

    /// Rebuild the per-layer window from the sidecars tiling `[base, base + n)`.
    /// `blocks` must be in ascending absolute-position order and contiguous.
    ///
    /// Mirrors `SSDPrefixCache.rebuildPrefix`: descriptors and byte counts are
    /// validated BEFORE any `MLXArray` init, whose shape/byte mismatch is an
    /// uncatchable trap. nil on any inconsistency ⇒ the caller drops the
    /// window and the adopter replays, which is always safe.
    static func rebuildWindow(
        blocks: [(metadata: SSDBlockMetadata, chunks: [Data])],
        geometry: SSDWindowSidecarGeometry,
        base: Int,
        dtypeByName: [String: DType]
    ) -> [Window?]? {
        guard blocks.count == geometry.blocksPerWindow, let first = blocks.first else {
            return nil
        }
        let descriptors = first.metadata.chunks
        guard descriptors.count == geometry.layers.count * 2 else { return nil }
        for block in blocks {
            guard block.metadata.chunks == descriptors,
                block.metadata.layerCount == geometry.layerCount,
                block.chunks.count == descriptors.count
            else { return nil }
        }
        for (d, desc) in descriptors.enumerated() {
            let layer = geometry.layers[d / 2]
            guard desc.layerIndex == layer.index, desc.tensor == d % 2,
                desc.shape == [1, layer.kvHeads, geometry.blockSize, layer.headDim],
                let dtype = dtypeByName[desc.dtype]
            else { return nil }
            var expected = dtype.size
            for dim in desc.shape {
                guard dim > 0 else { return nil }
                let (product, overflow) = expected.multipliedReportingOverflow(by: dim)
                guard !overflow else { return nil }
                expected = product
            }
            for block in blocks where block.chunks[d].count != expected { return nil }
        }
        var restored: [Window?] = Array(repeating: nil, count: geometry.layerCount)
        var toEval: [MLXArray] = []
        toEval.reserveCapacity(geometry.layers.count * 2)
        for (i, layer) in geometry.layers.enumerated() {
            let keyDesc = descriptors[i * 2]
            let valueDesc = descriptors[i * 2 + 1]
            guard let keyDType = dtypeByName[keyDesc.dtype],
                let valueDType = dtypeByName[valueDesc.dtype]
            else { return nil }
            var keyParts: [MLXArray] = []
            var valueParts: [MLXArray] = []
            keyParts.reserveCapacity(blocks.count)
            valueParts.reserveCapacity(blocks.count)
            for block in blocks {
                keyParts.append(MLXArray(block.chunks[i * 2], keyDesc.shape, dtype: keyDType))
                valueParts.append(
                    MLXArray(block.chunks[i * 2 + 1], valueDesc.shape, dtype: valueDType))
            }
            let keys = keyParts.count == 1 ? keyParts[0] : concatenated(keyParts, axis: 2)
            let values = valueParts.count == 1 ? valueParts[0] : concatenated(valueParts, axis: 2)
            guard keys.dim(2) == geometry.windowTokens else { return nil }
            restored[layer.index] = (keys: keys, values: values, base: base)
            toEval.append(keys)
            toEval.append(values)
        }
        eval(toEval)
        return restored
    }
}

// MARK: - Donor seam

extension CBv2WindowedSequenceKV {
    /// The contiguous ring's window in WS-4.1's frozen
    /// `PagedSequenceKV.windowSnapshot() -> (keys:values:base:)?` shape
    /// (`PagedSeamContract.swift:169-173`), resolved through the shared
    /// `snapshot()` → `(base)` arithmetic. `snapshot()` already returns the
    /// ring in temporal order plus the row's absolute offset, so contiguous
    /// gemma-4 produces sidecars with no paged dependency (the plan's open
    /// question at §12).
    ///
    /// Used ONLY by the state-based `SSDPrefixCache.donate(tokens:state:…)`
    /// overload, which is a `CBv2PrefixCache` requirement but not the
    /// production route: the engine already holds the rows and snapshots
    /// them on its own thread, handing the triples over through
    /// `CBv2SlidingWindowDonating` for the cache to resolve with
    /// `SSDWindowSidecar.windows(fromSnapshots:)`. Both routes share
    /// `SSDWindowSidecar.window(fromSnapshot:)`.
    ///
    /// This used to be reached through an `SSDWindowSnapshotting` protocol
    /// with one conformer and a runtime `as?` probe, anticipating a
    /// `PagedSequenceKV` conformance that WS-4.1 never landed. The probe is
    /// now a concrete cast; add the protocol back if and when a second row
    /// type can actually answer.
    func windowSnapshot() -> (keys: MLXArray, values: MLXArray, base: Int)? {
        SSDWindowSidecar.window(fromSnapshot: snapshot())
    }
}
