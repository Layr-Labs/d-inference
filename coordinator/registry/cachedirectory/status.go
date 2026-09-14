package cachedirectory

import (
	"time"
)

type LifecycleStatus struct {
	SSDLookups       uint64            `json:"ssd_lookups"`
	SSDHits          uint64            `json:"ssd_hits"`
	SSDMisses        uint64            `json:"ssd_misses"`
	SSDDonations     uint64            `json:"ssd_donations"`
	HolderAdded      uint64            `json:"holder_added"`
	HolderRemoved    map[string]uint64 `json:"holder_removed"`
	DonationOutcomes map[string]uint64 `json:"donation_outcomes"`
}

func zeroUint64Buckets(values []string) map[string]uint64 {
	result := make(map[string]uint64, len(values))
	for _, value := range values {
		result[value] = 0
	}
	return result
}

func (t *Directory[C]) RecordDonationOutcomes(deltas map[string]uint64) {
	if t == nil || len(deltas) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for outcome, delta := range deltas {
		if delta == 0 || !containsFixed(t.donationOutcomeNames, outcome) {
			continue
		}
		current := t.donationOutcomes[outcome]
		if ^uint64(0)-current < delta {
			t.donationOutcomes[outcome] = ^uint64(0)
		} else {
			t.donationOutcomes[outcome] = current + delta
		}
	}
}

// Snapshot reports index cardinalities without exposing mutable evidence.
type Snapshot struct {
	Holders, Attempts, Buckets, HolderOrder, AttemptOrder, Sequences, Rejected int
}

func (t *Directory[C]) Snapshot() Snapshot {
	t.mu.Lock()
	defer t.mu.Unlock()
	return Snapshot{Holders: t.holderCount, Attempts: len(t.attempts), Buckets: len(t.holders), HolderOrder: len(t.holderOrder), AttemptOrder: len(t.attemptOrder), Sequences: len(t.v2Sequences), Rejected: len(t.rejectedV2)}
}

// StateCounts retains the periodic expiry sweep used by coordinator status.
func (t *Directory[C]) StateCounts(now time.Time) (holders, attempts int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	return t.holderCount, len(t.attempts)
}

// AttemptDeadline observes receipt retention without returning the attempt's
// nonce-bound prompt or mutable boundary map.
func (t *Directory[C]) AttemptDeadline(nonce string) (time.Time, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	attempt, exists := t.attempts[nonce]
	return attempt.ExpiresAt, exists
}
func containsFixed(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func (t *Directory[C]) LifecycleStatus() LifecycleStatus {
	t.mu.Lock()
	defer t.mu.Unlock()
	holderRemoved := zeroUint64Buckets(HolderRemovalReasons())
	for reason, count := range t.holderRemoved {
		holderRemoved[reason] = count
	}
	donationOutcomes := zeroUint64Buckets(t.donationOutcomeNames)
	for outcome, count := range t.donationOutcomes {
		donationOutcomes[outcome] = count
	}
	return LifecycleStatus{
		SSDLookups: t.ssdLookups, SSDHits: t.ssdHits,
		SSDMisses: t.ssdMisses, SSDDonations: t.ssdDonations,
		HolderAdded: t.holderAdded, HolderRemoved: holderRemoved,
		DonationOutcomes: donationOutcomes,
	}
}
