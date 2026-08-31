// Copyright © 2026 Eigen Labs.
//
// KV grant re-slicing for multi-model co-residency on the v2 engine
// (v0.7.5 — the root fix for the Jul 4–6 gemma postmortem layer 5).
//
// Before this, the FIRST v2 engine on a box claimed the entire KV budget as
// a construction-fixed ceiling; every later model found `remaining == 0`
// and silently fell back to the legacy scheduler (cap 24, eager decode,
// 2–3 tok/s at batch ≥ 4). With the engine's admission ceiling now
// runtime-resizable (`CBv2Engine.updateKVBytesCapacity`, mlx-swift-lm
// `cbv2/v075-engine`), the provider re-slices grants at every load/unload:
//
//   * ON LOAD: shrink existing engines to their fair shares FIRST, then
//     construct the newcomer with `fleetBudget − Σ(post-shrink shares)`.
//     Shrink semantics are safe by construction (engine-side): in-flight
//     reservations are untouched; new reserves fail (`capacityExhausted` →
//     the scheduler queues/preempts) until the pool drains below the new
//     ceiling.
//   * ON UNLOAD: grow survivors back to their re-sliced shares.
//
// Fair share ∝ `fp16KVBytesPerToken × min(maxContextLength, contextCap)`
// per model (equal split when any weight is unknown). A SINGLE-model box
// keeps the FULL fleet budget — sharing only starts at ≥ 2 v2 slots; a
// static budget/maxModelSlots split would strand ⅔ of the KV on dedicated
// boxes. Invariant: Σ(grants) ≤ fleetBudget at all times.
//
// Serviceability floor: a load whose re-slice would leave ANY slot below
// the minimum serveable KV (`UnifiedMemoryCap.minimumLoadKVBytes`, the same
// 1 GiB figure the post-load headroom guard enforces) is REFUSED — fail
// loud (503, coordinator reroutes) rather than thrashing every co-resident
// model below serviceability.

import Foundation

extension EngineV2KVSizing {

    /// Context-length cap for re-slice weights: a 262k-context model must
    /// not claim 2× the share of a 131k one — beyond this, extra context
    /// stops earning budget (the fleet routes long-context work by
    /// token-budget admission, not by parking half the box's KV on it).
    static let resliceContextCap = 131_072

    /// One model's sizing inputs for `resliceGrants`.
    struct ResliceSlot: Sendable, Equatable {
        let modelId: String
        /// fp16 per-token KV rate (`SlotSizingSnapshot.fp16KVBytesPerToken`);
        /// ≤ 0 = unknown ⇒ the whole re-slice degrades to an equal split.
        let fp16KVBytesPerToken: Int
        /// Model context window; ≤ 0 = unknown (weight uses the cap alone).
        let maxContextLength: Int

        init(modelId: String, fp16KVBytesPerToken: Int, maxContextLength: Int) {
            self.modelId = modelId
            self.fp16KVBytesPerToken = fp16KVBytesPerToken
            self.maxContextLength = maxContextLength
        }
    }

    /// Fair-share KV grants for every v2 slot on the box (existing +
    /// optional newcomer), against the CURRENT fleet KV budget
    /// (`UnifiedMemoryCap.kvBudgetBytes` over Σ ALL resident weights,
    /// including the newcomer's). Pure policy:
    ///
    ///   * one slot ⇒ the full budget (never a static N-way split);
    ///   * ≥ 2 slots ⇒ share_i = budget × w_i / Σw with
    ///     w_i = rate_i × min(maxContext_i, 131_072);
    ///   * any unknown weight (rate ≤ 0) ⇒ equal split (degenerate);
    ///   * Σ(shares) ≤ budget always (floor division; the ≤ slot-count
    ///     remainder bytes are deliberately left unassigned).
    ///
    /// Returns modelId → grant bytes. The caller enforces the
    /// serviceability floor (`resliceMeetsServiceabilityFloor`) on LOAD.
    static func resliceGrants(
        existing: [ResliceSlot],
        newcomer: ResliceSlot?,
        fleetKVBudgetBytes: UInt64
    ) -> [String: Int] {
        var all = existing
        if let newcomer { all.append(newcomer) }
        guard !all.isEmpty else { return [:] }

        let budget = min(fleetKVBudgetBytes, UInt64(Int.max))

        // Single-model box: the full fleet budget, exactly as today.
        if all.count == 1 {
            return [all[0].modelId: Int(budget)]
        }

        // Per-model weights. Any unknown rate degrades the WHOLE slice to
        // an equal split — mixing real weights with a guessed one would
        // silently starve whichever side the guess was wrong about.
        var weights: [UInt64] = []
        weights.reserveCapacity(all.count)
        var degenerate = false
        for slot in all {
            guard slot.fp16KVBytesPerToken > 0 else {
                degenerate = true
                break
            }
            let context = slot.maxContextLength > 0
                ? min(slot.maxContextLength, resliceContextCap)
                : resliceContextCap
            let (w, overflow) = UInt64(slot.fp16KVBytesPerToken)
                .multipliedReportingOverflow(by: UInt64(context))
            weights.append(overflow ? .max : w)
        }
        if !degenerate {
            let total = weights.reduce(UInt64(0)) { partial, w in
                let (sum, overflow) = partial.addingReportingOverflow(w)
                return overflow ? .max : sum
            }
            degenerate = total == 0 || total == .max
        }

        var grants: [String: Int] = [:]
        if degenerate {
            let share = budget / UInt64(all.count)
            for slot in all { grants[slot.modelId] = Int(share) }
            return grants
        }

        let totalWeight = weights.reduce(UInt64(0), +)
        for (index, slot) in all.enumerated() {
            // budget × w / Σw without UInt64 overflow: budget ≤ Int.max
            // (2^63) and w/Σw ≤ 1, so route through Double for the ratio
            // and floor. Double's 52-bit mantissa can smear ≤ a few hundred
            // bytes at petabyte scales — irrelevant against GiB grants, and
            // always ≤ the true share + 1 ULP, re-clamped below.
            let ratio = Double(weights[index]) / Double(totalWeight)
            let share = UInt64(Double(budget) * ratio)
            grants[slot.modelId] = Int(min(share, budget))
        }
        // Re-clamp: floor arithmetic keeps Σ ≤ budget, but defend against
        // ULP smear pushing the sum over by shaving the largest grant.
        let sum = grants.values.reduce(0) { $0 + UInt64($1) }
        if sum > budget, let largest = grants.max(by: { $0.value < $1.value }) {
            let over = Int(sum - budget)
            grants[largest.key] = max(0, largest.value - over)
        }
        return grants
    }

    /// The serviceability floor a LOAD-time re-slice must clear for every
    /// slot: the same 1 GiB minimum-serveable-KV figure the post-load
    /// headroom guard (`UnifiedMemoryCap.loadIsServeable`) enforces. A
    /// grant below it means the slot would reject essentially every
    /// request at admission — so the LOAD is refused instead of thrashing
    /// every co-resident model below serviceability.
    static var minimumServiceableGrantBytes: UInt64 {
        UnifiedMemoryCap.minimumLoadKVBytes
    }

    /// True iff every grant clears the serviceability floor.
    ///
    /// `fixedCarveBytes` (T-041 composition): an EXISTING slot's prefix-
    /// cache budget is construction-fixed and carved out of its total
    /// claim, so the floor must hold for what would remain for its ENGINE
    /// (`grant − carve`) — a total that only covers the cache would leave
    /// the slot rejecting every request. Slots absent from the map (the
    /// newcomer and existing slots are floored on the live-KV grant.
    static func resliceMeetsServiceabilityFloor(
        _ grants: [String: Int],
        fixedCarveBytes: [String: Int] = [:]
    ) -> Bool {
        grants.allSatisfy { modelId, grant in
            let engineShare = grant - (fixedCarveBytes[modelId] ?? 0)
            return UInt64(max(0, engineShare)) >= minimumServiceableGrantBytes
        }
    }
}
