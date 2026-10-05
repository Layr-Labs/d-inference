package trust

import (
	"time"

	trustcoverage "github.com/eigeninference/d-inference/coordinator/internal/provider/coverage"
)

// TrustCoverageLoop drives the batched periodic coverage writes until the
// server closes. One goroutine for the whole fleet.
func (s *Owner) TrustCoverageLoop() {
	ticker := time.NewTicker(trustcoverage.WriteInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.trustCoverageCtx.Done():
			return
		case <-ticker.C:
			s.SweepTrustCoverage()
			s.SweepCodeAttestCoverage()
		}
	}
}
