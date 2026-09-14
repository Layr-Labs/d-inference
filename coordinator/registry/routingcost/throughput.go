package routingcost

import (
	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
)

// EffectiveDecodeTPS scales the static decode TPS down by current
// backend batch size. Returns the static value when the load factor is
// disabled or batch is unknown. Floored at 1 token/s to avoid divide-
// by-zero.
//
// Note on the floor + large reqMax: when effectiveTPS bottoms out, the
// per-request decode cost (reqMax / effectiveTPS * 1000) can become
// very large for big reqMax values. This is intentional — a saturated
// provider should look strictly worse than less-saturated peers — and
// the maxConcurrency gate in snapshotProviderIntoLockedEx already prevents
// us from getting here when batchSize exceeds the per-tier cap.
func EffectiveDecodeTPS(staticTPS float64, backendRunning int) float64 {
	if staticTPS <= 0 {
		return 1.0
	}
	if throughput.LoadFactor <= 0 || backendRunning <= 0 {
		return staticTPS
	}
	tps := staticTPS / (1.0 + throughput.LoadFactor*float64(backendRunning))
	if tps < 1.0 {
		tps = 1.0
	}
	return tps
}

// DecodeFloorUseFleetMedian gates the tier-2 (fleet-median) solo-rate source in
// ProjectedPerRequestDecodeTPS. Read LIVE (no restart); default ON. Set
// EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN=false for byte-for-byte pre-fix
// behavior (idle boxes fall straight to the static benchmark).
func DecodeFloorUseFleetMedian() bool {
	return env.EnvBool(env.EnvPrefix+"_DECODE_FLOOR_USE_FLEET_MEDIAN", true)
}

// ResolveEffectiveTPS returns the best available decode TPS estimate.
// Fallback chain: observed EWMA → fleet median → load-scaled benchmark.
func ResolveEffectiveTPS[Connection comparable](snap *Snapshot[Connection]) float64 {
	if snap.ObservedDecodeTPS > 0 {
		return snap.ObservedDecodeTPS
	}
	if snap.FleetMedianTPS > 0 {
		return snap.FleetMedianTPS
	}
	return EffectiveDecodeTPS(snap.DecodeTPS, snap.BackendRunning)
}

// ResolvePrefillTPS returns the best available prefill TPS estimate for TTFT.
// Fallback chain: measured per-slot observed prefill EWMA → snap.prefillTPS (the
// resolvedPrefillTPS chain: registration benchmark → decode×prefillToDecodeRatio
// ×12 fallback). This mirrors how ResolveEffectiveTPS prefers the measured
// decode rate over the static estimate. The result is clamped to MaxPrefillTPS
// so a single outlier heartbeat cannot collapse the TTFT estimate.
//
// observedPrefillTPS stays 0 until providers ship the W1 measurement, so on
// today's fleet this is a no-op that returns the existing ×12-chain value.
func ResolvePrefillTPS[Connection comparable](snap *Snapshot[Connection]) float64 {
	tps := snap.PrefillTPS
	if snap.ObservedPrefillTPS > 0 {
		tps = snap.ObservedPrefillTPS
	}
	if tps > MaxPrefillTPS {
		tps = MaxPrefillTPS
	}
	return tps
}

// Occupancy is the per-(provider,model) in-flight occupancy the
// coordinator already tracks: max(pendingForModel, backend_running +
// backend_waiting). pendingForModel is the coordinator's own dispatched-but-not-
// yet-terminal count (incremented at reserve, held the whole dark-time), so this
// is herd-aware even when the heartbeat gauge still reads backend_running=0 — no
// parallel reservation counter is needed. It is the same quantity the routing
// cost's effectiveQueue and the quality-concurrency cap consume; the Phase-0
// occupancy-aware TTFT term and the shadow admission/spread evaluator reuse it so
// every occupancy-keyed decision reads one signal.
func Occupancy[Connection comparable](snap *Snapshot[Connection]) int {
	occ := snap.PendingForModel
	if backendDepth := snap.BackendRunning + snap.BackendWaiting; backendDepth > occ {
		occ = backendDepth
	}
	if occ < 0 {
		occ = 0
	}
	return occ
}

// ProjectedPerRequestDecodeTPS estimates the decode tokens/sec a NEWLY admitted
// request would receive on this snapshot's provider once it joins the batch
// (backendRunning+1 concurrent). Continuous batching is memory-bandwidth bound,
// so per-request decode degrades with batch size by the same effectiveTPSLoadFactor
// model used elsewhere: rate(b) = solo / (1 + k·b). The measured observed decode
// rate (when present) is unwound from the current batch to a solo rate and then
// reapplied at b+1; otherwise the static benchmark is the solo proxy. Used by the
// decode-floor quality preference (PendingRequest.MinDecodeTPS).
func ProjectedPerRequestDecodeTPS[Connection comparable](snap *Snapshot[Connection]) float64 {
	return ProjectedPerRequestDecodeTPSAtBatch(snap, snap.BackendRunning)
}

// ProjectedPerRequestDecodeTPSAtBatch is ProjectedPerRequestDecodeTPS with an
// EXPLICIT batch the new request would join, used when the heartbeat gauge
// (backend_running) understates real contention. The observed-rate UNWIND always
// uses the batch the observation was actually taken at (snap.backendRunning —
// the heartbeat's observedDecodeTPS pairs with that gauge), while the REAPPLY
// uses joinBatch. Passing joinBatch == snap.backendRunning reproduces the
// original result exactly, so the decode-floor caller is byte-for-byte unchanged;
// the occupancy term passes joinBatch == occ so a herd that has already reserved
// peers the heartbeat has not yet reflected (occ > backend_running) is charged at
// the contended rate it will actually see — not the idle/low-batch rate.
func ProjectedPerRequestDecodeTPSAtBatch[Connection comparable](snap *Snapshot[Connection], joinBatch int) float64 {
	k := throughput.LoadFactor
	if k < 0 {
		k = 0
	}
	bObserved := snap.BackendRunning
	if bObserved < 0 {
		bObserved = 0
	}
	if joinBatch < 0 {
		joinBatch = 0
	}
	// Solo (b=0) decode-rate base, durable 3-tier chain:
	solo := snap.DecodeTPS // tier 3: static benchmark (last resort)
	switch {
	case snap.ObservedDecodeTPS > 0:
		// tier 1: this box's own LIVE measured rate, unwound from the batch it
		// was measured at (bObserved) to solo.
		solo = snap.ObservedDecodeTPS * (1 + k*float64(bObserved))
	case DecodeFloorUseFleetMedian() && snap.FleetMedianTPS > 0:
		// tier 2: durable per-(model,chip) observed median from the tps registry.
		// Exists even when this box is IDLE, so a historically-slow chip (e.g. the
		// ~9 tok/s gemma boxes driving client_gone) is deprioritized BEFORE it gets
		// packed — the static benchmark (~23) otherwise made idle slow boxes look
		// fast. Conservative for a quality floor: a median that understates true
		// solo biases AWAY from borderline boxes (the safe direction).
		solo = snap.FleetMedianTPS
	}
	if solo <= 0 {
		return 0
	}
	return solo / (1 + k*float64(joinBatch+1))
}

// MaxPrefillTPS bounds reported and predicted prefill throughput.
const MaxPrefillTPS = 5000.0
