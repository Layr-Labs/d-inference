import Foundation

/// Pure logic for "can this box actually load the model it would be assigned?"
///
/// A box can be ONLINE and hardware-trusted yet fail every request because the
/// assigned model doesn't fit its RAM ("Insufficient memory (X GB free, need Y
/// GB)"). This turns the raw numbers into an operator-facing verdict.
///
/// Delegates to `ModelLoadAdmission` — the SAME per-sample arithmetic the running
/// provider uses in `ProviderLoop.availableMemoryGb()` / `ensureModelLoaded`.
/// (Before, this modelled an older `weights × 2.0` / `free × 0.7` gate that no
/// longer matches the runtime.)
///
/// Sharing the arithmetic is NOT the same as sharing the decision, and this
/// docstring used to claim it was. `doctor` runs outside the daemon: it takes ONE
/// non-reclaiming sample, while the daemon's gate is a loop that LRU-evicts idle
/// models, drops the MLX buffer cache and RE-SAMPLES before refusing
/// (`ProviderLoop.evictUntilAvailable`). On a box holding a resident model the two
/// disagree by roughly that model's footprint — which is why `doctor` failed boxes
/// the daemon serves, and told their operators to shrink `enabled_models`.
///
/// So the verdict is bounded, not asserted: `usableGb` is the floor a CLI can
/// see, `usableAfterReclaimGb` is the ceiling the reclaim loop could reach, and a
/// requirement landing between them is reported as a WARN that says so. The
/// ceiling only ever WITHHOLDS a failure — it never grants a pass. That asymmetry
/// is what lets it over-credit safely: it assumes every resident byte is
/// evictable, which is looser than the daemon's own feasibility credit, and
/// clearing the eviction loop is not the last gate anyway (`claimPendingLoad`,
/// then the post-load serveability probe). `DaemonState.inferenceActive` could
/// narrow it, but gating on a signal that is both staler and strictly narrower
/// than `ProviderLoop.hasInflightWork` would reintroduce false refusals without
/// preventing a single false pass, since there are none to prevent.
public enum ModelFitDiagnostic {
    private static let gib = 1024.0 * 1024.0 * 1024.0

    private static func bytes(_ gb: Double) -> UInt64 {
        guard gb > 0 else { return 0 }
        let b = (gb * gib).rounded()
        return b >= Double(UInt64.max) ? UInt64.max : UInt64(b)
    }

    /// Resident memory (GB) a model needs to load: the (overhead-padded) weight
    /// footprint plus one-request headroom — exactly `ensureModelLoaded`'s
    /// requirement. `estimatedMemoryGb` is the scanner's overhead-included size
    /// (the same value the runtime passes), not the raw on-disk bytes.
    /// `modelID` selects the model's measured activation floor
    /// (`UnifiedMemoryCap.measuredActivationFloorsBytes`) — the requirement a
    /// box serving ONLY this model faces, which is what a per-model fit
    /// verdict asks; nil keeps the flat default.
    public static func requiredGb(estimatedMemoryGb: Double, modelID: String? = nil) -> Double {
        // Cap-aware headroom (activation reserve + min serveable KV) so the
        // doctor's "needs ~X GB" matches what the runtime load gate requires.
        ModelLoadAdmission.requiredToLoadGb(
            weightsGb: estimatedMemoryGb,
            headroomGb: Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: modelID.map { [$0] }))
                / (1024.0 * 1024.0 * 1024.0))
    }

    /// The FLOOR only — `MemoryBasis.usableGb`. Real free RAM (clamped to what the
    /// OS reports available when known) minus the OS reserve and resident MLX
    /// memory, via `ModelLoadAdmission.freeForLoadGb`. The same per-sample
    /// arithmetic as `ProviderLoop.availableMemoryGb()`, but not the same
    /// decision — that method runs inside a reclaim loop and this does not.
    /// Prefer `memoryBasis` where the ceiling matters.
    ///
    /// - Parameters:
    ///   - systemAvailableGb: real OS-reported available memory (doctor reads it
    ///     live on the same machine). Pass nil when unknown to fall back to the
    ///     total-minus-resident view.
    public static func usableInferenceGb(
        totalGb: Double,
        reserveGb: Double,
        systemAvailableGb: Double? = nil,
        gpuActiveGb: Double = 0,
        gpuCacheGb: Double = 0
    ) -> Double {
        memoryBasis(
            totalGb: totalGb, reserveGb: reserveGb, systemAvailableGb: systemAvailableGb,
            gpuActiveGb: gpuActiveGb, gpuCacheGb: gpuCacheGb
        ).usableGb
    }

    /// The two bounds a diagnostic run outside the daemon can honestly establish.
    /// Returned as a pair so the floor and the ceiling are always computed from
    /// one set of inputs and cannot drift apart at the call site.
    public struct MemoryBasis: Sendable, Equatable {
        /// What one non-reclaiming sample sees — resident MLX memory subtracted
        /// as consumed. Identical to what `doctor` has always reported.
        public let usableGb: Double
        /// The ceiling the daemon's load gate could reach by evicting idle models
        /// and dropping the MLX buffer cache. Equal to `usableGb` when nothing is
        /// resident, so an offline run is unchanged.
        public let afterReclaimGb: Double
        public init(usableGb: Double, afterReclaimGb: Double) {
            self.usableGb = usableGb
            self.afterReclaimGb = afterReclaimGb
        }
    }

    /// Both bounds for one box. See `MemoryBasis`.
    public static func memoryBasis(
        totalGb: Double,
        reserveGb: Double,
        systemAvailableGb: Double? = nil,
        gpuActiveGb: Double = 0,
        gpuCacheGb: Double = 0
    ) -> MemoryBasis {
        let totalBytes = bytes(totalGb)
        // Same cap-implied reserve the running gate uses (max(configReserve,
        // physical − 90% cap)), so the doctor verdict matches what the daemon
        // actually enforces and never reports "fits" for a model the cap refuses.
        let reserve = UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: totalBytes, configReserveBytes: bytes(reserveGb))
        let systemAvailableBytes = systemAvailableGb.map(bytes) ?? .max
        let gpuActive = bytes(gpuActiveGb)
        let gpuCache = bytes(gpuCacheGb)
        let usable = ModelLoadAdmission.freeForLoadGb(
            totalBytes: totalBytes,
            systemAvailableBytes: systemAvailableBytes,
            gpuActiveBytes: gpuActive,
            gpuCacheBytes: gpuCache,
            reserveBytes: reserve,
            outstandingReservationBytes: 0)
        // The load gate's own reclaim, priced the way it prices it: our resident
        // MLX memory returns to the OS when an idle model is unloaded, so it is
        // ADDED BACK to system-available rather than merely not subtracted.
        let (sumUsed, usedOverflow) = gpuActive.addingReportingOverflow(gpuCache)
        let mlxUsed = usedOverflow ? UInt64.max : sumUsed
        let afterReclaim = ModelLoadAdmission.freeForLoadAfterReclaimGb(
            totalBytes: totalBytes,
            systemAvailableBytes: systemAvailableBytes,
            mlxUsedBytes: mlxUsed,
            reserveBytes: reserve,
            outstandingReservationBytes: 0)
        return MemoryBasis(usableGb: usable, afterReclaimGb: max(usable, afterReclaim))
    }

    /// A candidate model the operator could serve instead, with its size.
    public struct ModelOption: Sendable, Equatable {
        public let id: String
        public let weightGb: Double
        public init(id: String, weightGb: Double) {
            self.id = id
            self.weightGb = weightGb
        }
    }

    /// Builds the traffic-readiness diagnostic for a single target model.
    /// `weightGb` is the model's overhead-included estimated size; `alternatives`
    /// are locally-available models, used to suggest a fit. `servingSetIDs` is
    /// the box's ACTUAL serving set (the daemon's load gate carves the max
    /// floor over that whole set, not the target's own) — pass it so the
    /// verdict matches what the daemon enforces; nil falls back to the target
    /// alone (a single-model box, where the two coincide).
    ///
    /// `usableAfterReclaimGb` is `MemoryBasis.afterReclaimGb` — the ceiling the
    /// daemon's eviction loop could reach. nil means no ceiling is known and the
    /// verdict collapses to the single-bound behaviour. It is used only to
    /// WITHHOLD a failure, never to grant a pass.
    public static func diagnose(
        modelID: String,
        weightGb: Double,
        usableGb: Double,
        usableAfterReclaimGb: Double? = nil,
        alternatives: [ModelOption] = [],
        servingSetIDs: [String]? = nil
    ) -> Diagnostic {
        // A zero sample is not "unknown" when a reclaim ceiling is known: an
        // OS-available reading below the reserve floors the sample at 0 on
        // exactly the boxes this check exists for. Fall through on the ceiling
        // rather than discarding a bound we actually have.
        guard weightGb > 0, max(usableGb, usableAfterReclaimGb ?? 0) > 0 else {
            return Diagnostic(
                section: .traffic, name: "model fits in RAM", level: .warn,
                message: "couldn't determine the model size or available memory; skipping the fit check.",
                fix: nil)
        }
        // The daemon's requirement for THIS box: weights + headroom at the
        // serving set's floor (ProviderLoop.loadHeadroomGb), never the
        // target's solo floor when other enabled models pin a larger one. The
        // target always joins the basis — the daemon's set includes whatever
        // it is loading (max is idempotent, so a duplicate id is harmless).
        let needed = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: weightGb,
            headroomGb: Double(
                // nil = no declared set → the target alone (a single-model
                // box). An EMPTY declared set is the daemon's open world —
                // it advertises nothing, so the target cannot be joining it;
                // resolve at the default floor rather than the target's solo
                // floor.
                UnifiedMemoryCap.loadHeadroomBytes(
                    modelIDs: servingSetIDs.map { $0.isEmpty ? [] : $0 + [modelID] } ?? [modelID]))
                / (1024.0 * 1024.0 * 1024.0))
        if needed <= usableGb {
            return Diagnostic(
                section: .traffic, name: "model fits in RAM", level: .pass,
                message: "\(modelID) needs ~\(fmt(needed)) GB; \(fmt(usableGb)) GB usable.",
                fix: nil)
        }
        // #721: `usableGb` is ONE non-reclaiming sample taken from outside the
        // daemon. The daemon's load gate is a loop — evict idle models, drop the
        // MLX buffer cache, RE-SAMPLE (ProviderLoop.evictUntilAvailable) — and
        // reaches up to `usableAfterReclaimGb`. Between the two a CLI has no
        // evidence either way, and asserting a refusal there is what made doctor
        // FAIL boxes the daemon demonstrably serves, with a fix line that shrinks
        // a capable box's serving set.
        //
        // WARN, never PASS: this ceiling is looser than the daemon's own eviction
        // feasibility credit (evictionCanReach counts evictable slot weights plus
        // the MLX cache, not all resident memory), and clearing the loop is not
        // the last gate anyway (claimPendingLoad, the post-load serveability
        // probe). Only the daemon can prove a load succeeds.
        let ceilingGb = max(usableGb, usableAfterReclaimGb ?? usableGb)
        if needed <= ceilingGb {
            return Diagnostic(
                section: .traffic, name: "model fits in RAM", level: .warn,
                message: "\(modelID) needs ~\(fmt2(needed)) GB. This check sees \(fmt2(usableGb)) GB "
                    + "usable, but the daemon's load gate reclaims its own MLX memory first — "
                    + "evicting idle models and dropping the MLX buffer cache, then re-sampling — "
                    + "which raises the ceiling to at most \(fmt2(ceilingGb)) GB. `doctor` runs "
                    + "outside the daemon: it can neither perform that reclaim nor see what is in "
                    + "flight, so it cannot settle whether this model loads.",
                fix: "no `provider.toml` change is indicated by this check. If loads are actually "
                    + "failing, the daemon records the refusal — see `recent model load` below and "
                    + "`darkbloom logs`. `darkbloom doctor --strict` still exits non-zero here.")
        }
        // Each alternative is judged with ITS OWN activation floor — the
        // suggestion models what `enabled_models = [candidate]` would require.
        // Judged against the CEILING, not the current sample: the suggestion
        // models `enabled_models = [candidate]`, where the resident set this box
        // holds today is gone. Filtering against the sample would recommend a
        // smaller model than the box can serve — the same downgrade this check
        // exists to stop. With no ceiling known the two are equal.
        let fits = alternatives
            .filter { requiredGb(estimatedMemoryGb: $0.weightGb, modelID: $0.id) <= ceilingGb }
            .sorted { $0.weightGb > $1.weightGb }
        let suggestion: String
        if fits.isEmpty {
            suggestion = "this box's RAM is too small for the models on this network; consider a machine with more unified memory."
        } else {
            let list = fits.prefix(3).map { "\($0.id) (~\(fmt(requiredGb(estimatedMemoryGb: $0.weightGb, modelID: $0.id))) GB)" }.joined(separator: ", ")
            suggestion = "set `enabled_models` in provider.toml to a model that fits: \(list)."
        }
        let ceilingClause = ceilingGb > usableGb
            ? "at most \(fmt(ceilingGb)) GB is reachable even after the daemon evicts every idle model"
            : "only \(fmt(usableGb)) GB is usable"
        return Diagnostic(
            section: .traffic, name: "model fits in RAM", level: .fail,
            message: "\(modelID) needs ~\(fmt(needed)) GB but \(ceilingClause) — it will show online but every request fails to load.",
            fix: suggestion)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    /// The WARN prints three figures that can lie within 0.1 GB of one another,
    /// where one decimal renders them identically and the message reads as a
    /// contradiction ("needs 18.0, sees 18.0, can reach 18.0 — why warn?").
    private static func fmt2(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
