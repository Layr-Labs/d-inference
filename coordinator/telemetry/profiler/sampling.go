package profiler

import (
	"hash/fnv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	finalStatusSuccess      = "success"
	profileSlowFirstContent = 5 * time.Second
	profileSlowTotal        = 30 * time.Second
)

// sampled decides, per logical request, whether a success record is kept.
// Deterministic on the coordinator-minted id so every attempt of a request
// lands together; a missing id (no middleware) is always kept.
func (p *Profiler) sampled(coordID string) bool {
	if p == nil {
		return false
	}
	if p.sampleRate >= 1 || coordID == "" {
		return true
	}
	if p.sampleRate <= 0 {
		return false
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(coordID))
	// Map the hash to [0,1) and compare; FNV spreads short ids well enough for
	// a fixed-rate sample and costs no allocation.
	frac := float64(h.Sum32()) / float64(1<<32)
	return frac < p.sampleRate
}

// profileTimingAnomaly flags non-monotonic coordinator stamps (a retried
// attempt that re-stamped, a clock issue, or a bug). Never rejects the row.
func profileTimingAnomaly(rec *store.RequestProfileRecord) bool {
	order := []*int64{
		rec.HandlerEntryUS, rec.ParsedUS, rec.ReservedUS, rec.AttemptStartUS, rec.ReserveDoneUS,
		rec.EncryptedUS, rec.WriteSubmittedUS, rec.WriteDequeuedUS, rec.WriteDoneUS,
		rec.FirstChunkIngressUS, rec.FirstContentUS, rec.CompleteIngressUS,
	}
	var last int64
	for _, p := range order {
		if p == nil {
			continue
		}
		if *p < last {
			return true
		}
		last = *p
	}
	return false
}

// alwaysRecord reports whether a record bypasses sampling.
func (p *Profiler) alwaysRecord(rec *store.RequestProfileRecord) bool {
	if rec == nil {
		return false
	}
	if rec.FinalStatus != finalStatusSuccess {
		return true
	}
	if rec.FirstContentUS != nil && *rec.FirstContentUS > profileSlowFirstContent.Microseconds() {
		return true
	}
	if rec.FinalizedUS != nil && *rec.FinalizedUS > profileSlowTotal.Microseconds() {
		return true
	}
	if rec.AttemptsTotal > 1 || rec.BackupLaunched || rec.TimingAnomaly || rec.ClientGonePhase != "" {
		return true
	}
	if !rec.ProviderProfileValid && rec.ProviderProfileInvalidReason != providerProfileAbsent {
		return true
	}
	return false
}
