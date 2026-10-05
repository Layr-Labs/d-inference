package trust

import (
	"os"

	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func (s *Owner) Start() {
	if _, clampedDown := trustreuse.TrustReuseReconnectGapFromEnv(); clampedDown {
		s.logger.Warn("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP exceeds the 120s security ceiling; clamping DOWN",
			"requested", os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"),
			"allowance", trustreuse.MaxTrustReuseReconnectGap,
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
	s.StopReplay()
	if s.verificationBackend.Scheduler != nil {
		s.verificationBackend.Scheduler.Close()
	}
}

func (s *Owner) Close() { s.Quiesce(); s.CloseAuthority() }
