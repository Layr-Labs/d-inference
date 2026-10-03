package trust

import (
	"os"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func (s *Owner) Start() {
	if _, clampedDown := trustReuseReconnectGapFromEnv(); clampedDown {
		s.logger.Warn("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP exceeds the 120s security ceiling; clamping DOWN",
			"requested", os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"),
			"allowance", maxTrustReuseReconnectGap,
			"reason", "a contiguous offline gap must stay below the RecoveryOS round-trip floor (Threat-Model T-036)")
	}
	saferun.Go(s.logger, "trustCoverageLoop", s.TrustCoverageLoop)
	s.AppAttestFeature().Start()
}

// Quiesce stops background verification and stamps the exact shutdown continuity
// boundary before the transport composition root flushes its observation sinks.
func (s *Owner) Quiesce() {
	if s == nil {
		return
	}
	if s.trustCoverageCancel != nil {
		s.trustCoverageCancel()
	}
	s.FinalTrustCoverageSweep()
	s.SweepCodeAttestCoverage()
	if s.trustReplayCancel != nil {
		s.trustReplayCancel()
	}
	if s.mdmScheduler != nil {
		s.mdmScheduler.Close()
	}
}

func (s *Owner) Close() { s.Quiesce(); s.CloseAuthority() }

// CloseAuthority runs after route telemetry is flushed, preserving shutdown order.
func (s *Owner) CloseAuthority() {
	if s == nil {
		return
	}
	s.trustAuthorityMu.Lock()
	if s.trustAuthority != nil {
		_ = s.trustAuthority.Close()
		s.trustAuthority = nil
	}
	s.trustAuthorityMu.Unlock()
}
