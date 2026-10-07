package coverage

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

const WriteInterval = 30 * time.Second

// markTrustCoverage registers seKey as covered by providerID's live
// connection. Called only from grant paths that just proved the connection
// (full live verification or a reuse grant behind a fresh SE challenge).
func (s *Tracker,

) MarkTrustCoverage(seKey, providerID string) {
	if s == nil || seKey == "" || providerID == "" {
		return
	}
	s.trustCoverageMu.Lock()
	if s.trustCoverage == nil {
		s.trustCoverage = make(map[string]string)
	}
	s.trustCoverage[seKey] = providerID
	s.trustCoverageMu.Unlock()
}

// dropTrustCoverage ends coverage for an identity WITHOUT a final write
// (hard untrust: the tombstone wins, coverage never resurrects).
func (s *Tracker,

) DropTrustCoverage(seKey string) {
	if s == nil || seKey == "" {
		return
	}
	s.trustCoverageMu.Lock()
	delete(s.trustCoverage, seKey)
	s.trustCoverageMu.Unlock()
}

// trustCoverageValid reports whether the covered connection is still worth a
// coverage write: provider present, not (recoverably or hard) untrusted, still
// hardware-trusted, and still bound to the same SE identity. allowOffline is
// set by the disconnect/shutdown sweeps, where the socket being gone is the
// event being stamped rather than a reason to skip the stamp.
func (s *Tracker,

) trustCoverageValid(seKey, providerID string, allowOffline bool) bool {
	if s.registry == nil {
		return false
	}
	p := s.registry.GetProvider(providerID)
	if p == nil {
		return false
	}
	switch p.GetStatus() {
	case registry.StatusUntrusted:
		return false
	case registry.StatusOffline:
		if !allowOffline {
			return false
		}
	}
	if p.GetTrustLevel() != registry.TrustHardware {
		return false
	}
	ar := p.GetAttestationResult()
	return ar != nil && ar.PublicKey == seKey
}

// persistTrustCoverage advances the watermark for the given identities in the
// cache and, when a store is wired, durably in one batched pass. A store blip
// only under-advances the durable watermark (fail-safe).
func (s *Tracker,

) persistTrustCoverage(seKeys []string, until time.Time) {
	if len(seKeys) == 0 || s.trustReuseCache == nil {
		return
	}
	s.trustReuseCache.AdvanceCoverage(seKeys, until)
	st := s.trustReuseCache.Store
	if st == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	err := st.AdvanceProviderTrustReuseCoverage(ctx, seKeys, until)
	cancel()
	if err != nil && s.logger != nil {
		s.logger.Warn("trust-reuse: failed to persist continuity coverage",
			"error", err, "providers", len(seKeys))
	}
}

// sweepTrustCoverage performs one batched periodic coverage pass: every entry
// still observed live and hardware-trusted is advanced to now; entries that
// lost trust or vanished without hitting the disconnect hook are dropped
// without a write (their watermark stays at the previous pass — gap
// over-estimated, fail-safe). Returns the number of identities advanced.
func (s *Tracker,

) SweepTrustCoverage() int {
	if s == nil || s.trustReuseCache == nil {
		return 0
	}
	now := s.trustReuseCache.Now()
	var covered []string
	s.trustCoverageMu.Lock()
	for seKey, providerID := range s.trustCoverage {
		if s.trustCoverageValid(seKey, providerID, false) {
			covered = append(covered, seKey)
		} else {
			delete(s.trustCoverage, seKey)
		}
	}
	s.trustCoverageMu.Unlock()
	s.persistTrustCoverage(covered, now)
	return len(covered)
}

// StopTrustCoverageForProvider ends coverage for a disconnecting connection,
// stamping the EXACT coordinator-observed disconnect time so the measured
// reconnect gap starts at zero rather than at the last periodic pass.
func (s *Tracker,

) StopTrustCoverageForProvider(providerID string) {
	if s == nil || providerID == "" || s.trustReuseCache == nil {
		return
	}
	now := s.trustReuseCache.Now()
	var ended []string
	s.trustCoverageMu.Lock()
	for seKey, id := range s.trustCoverage {
		if id != providerID {
			continue
		}
		if s.trustCoverageValid(seKey, providerID, true) {
			ended = append(ended, seKey)
		}
		delete(s.trustCoverage, seKey)
	}
	s.trustCoverageMu.Unlock()
	s.persistTrustCoverage(ended, now)
}

// FinalTrustCoverageSweep is the graceful coordinator-shutdown sweep: it
// persists the exact shutdown instant for every still-covered provider so a
// short deploy (gap under the reconnect allowance) reconnects into a
// continuity fast-skip on the next coordinator instead of a fleet-wide live
// MDM herd. Clears the tracker; only Server.Close calls this.
func (s *Tracker,

) FinalTrustCoverageSweep() {
	if s == nil || s.trustReuseCache == nil {
		return
	}
	now := s.trustReuseCache.Now()
	var ended []string
	s.trustCoverageMu.Lock()
	for seKey, providerID := range s.trustCoverage {
		if s.trustCoverageValid(seKey, providerID, true) {
			ended = append(ended, seKey)
		}
		delete(s.trustCoverage, seKey)
	}
	s.trustCoverageMu.Unlock()
	s.persistTrustCoverage(ended, now)
}
