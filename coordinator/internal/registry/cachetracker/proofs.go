package cachetracker

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Proofs owns quarantine windows and lifecycle counters. The receipt controller
// serializes every operation under its existing mutex; no additional lock is taken.
type Proofs struct {
	generation                   *cacheplan.Generation
	rejectedV2                   *cacheindex.Records[FenceKey, FenceRecord]
	fencesApplied, fencesExpired uint64
}

const (
	ProofFenceBase      = 60 * time.Second
	ProofFenceMax       = 10 * time.Minute
	ProofFenceRetention = ProofFenceMax
)

func NewProofs(generation *cacheplan.Generation, records *cacheindex.Records[FenceKey, FenceRecord]) *Proofs {
	return &Proofs{generation: generation, rejectedV2: records}
}

// Counts supplies the two cumulative lifecycle metrics without settling windows.
func (t *Proofs) Counts() (applied, expired uint64) { return t.fencesApplied, t.fencesExpired }

func (t *Proofs) ClearRetired() { t.rejectedV2.Reset() }

// ForgetProvider clears a disconnected provider after evidence removal.
func (t *Proofs) ForgetProvider(providerID string, now time.Time) {
	for key, fence := range t.rejectedV2.Entries() {
		if key.ProviderID == providerID {
			t.Forget(key, fence, now)
		}
	}
}

// Reconcile forgets replaced capabilities, but preserves temporarily absent ones.
func (t *Proofs) Reconcile(providerID string, ssd, memory map[string]protocol.PrefixCacheV2Capability, now time.Time) {
	for key, fence := range t.rejectedV2.Entries() {
		if key.ProviderID != providerID {
			continue
		}
		current := ssd
		if key.Tier == "memory" {
			current = memory
		}
		if capability, ok := current[key.ModelID]; ok && capability != fence.Capability {
			t.Forget(key, fence, now)
		}
	}
}

func ProofFenceDuration(strikes uint32) time.Duration {
	duration := ProofFenceBase
	for strike := uint32(1); strike < strikes && duration < ProofFenceMax; strike++ {
		duration *= 2
	}
	return min(duration, ProofFenceMax)
}

// Rejected reports whether the advertised capability is currently
// fenced. It clears the record when the capability changed, never extends a
// window, and drops a lapsed record only once it is past the retention.
func (t *Proofs) Rejected(
	key FenceKey,
	capability protocol.PrefixCacheV2Capability,
	now time.Time,
) bool {
	fence, ok := t.rejectedV2.Load(key)
	if !ok {
		return false
	}
	if fence.Capability != capability {
		t.Forget(key, fence, now)
		return false
	}
	if fence.Active(now) {
		return true
	}
	t.settleLapsed(key, fence, now)
	return false
}

// Reject starts or escalates the fence for one mismatch. It returns
// true when the capability is fenced afterwards, including a mismatch that
// raced an already active window; that window is left unchanged.
func (t *Proofs) Reject(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
	now time.Time,
) bool {
	if !t.generation.Active() {
		return false
	}
	key := FenceKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	fence, ok := t.rejectedV2.Load(key)
	if ok {
		fence = t.countLapse(fence, now)
	}
	switch {
	case ok && fence.Capability == capability && fence.Active(now):
		return true
	case ok && fence.Capability == capability && !fence.Stale(now, ProofFenceRetention):
		if fence.Strikes < math.MaxUint32 {
			fence.Strikes++
		}
	default:
		fence = FenceRecord{Capability: capability, Strikes: 1}
	}
	fence.Until = now.Add(ProofFenceDuration(fence.Strikes))
	fence.Lapsed = false
	t.rejectedV2.Store(key, fence)
	t.fencesApplied++
	return true
}

// ResetStrikes forgets a lapsed fence once the same capability
// proves a receipt again. An active window is left alone: a receipt that
// passed the fence check before the window opened is not evidence it lifted.
func (t *Proofs) ResetStrikes(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
	now time.Time,
) {
	key := FenceKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	fence, ok := t.rejectedV2.Load(key)
	if !ok || fence.Capability != capability || fence.Active(now) {
		return
	}
	t.Forget(key, fence, now)
}

// countLapse charges a window that lifted by time to fences_expired
// exactly once, whichever path first observes it.
func (t *Proofs) countLapse(fence FenceRecord, now time.Time) FenceRecord {
	if !fence.Lapsed && !fence.Active(now) {
		fence.Lapsed = true
		t.fencesExpired++
	}
	return fence
}

func (t *Proofs) settleLapsed(
	key FenceKey, fence FenceRecord, now time.Time,
) {
	if fence.Stale(now, ProofFenceRetention) {
		t.Forget(key, fence, now)
		return
	}
	t.rejectedV2.Store(key, t.countLapse(fence, now))
}

// Forget drops a record for any reason (capability change,
// accepted proof, retention, provider disconnect) without losing the count
// of a window that had already lifted.
func (t *Proofs) Forget(
	key FenceKey, fence FenceRecord, now time.Time,
) {
	t.countLapse(fence, now)
	t.rejectedV2.Delete(key)
}

// Sweep bounds the fence map: every lapsed window is counted once
// and forgotten after the retention.
func (t *Proofs) Sweep(now time.Time) int {
	fenced := 0
	for key, fence := range t.rejectedV2.Entries() {
		if fence.Active(now) {
			fenced++
			continue
		}
		t.settleLapsed(key, fence, now)
	}
	return fenced
}
