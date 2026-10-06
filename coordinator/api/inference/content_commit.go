package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"

// NewContentCommitter binds first-content publication to the same calibration
// and registry authorities as provider terminal settlement.
func (s *Owner) NewContentCommitter() *attempt.ContentCommitter {
	return attempt.NewContentCommitter(attempt.ContentCommitDependencies{
		Registry: s.registry, Logger: s.logger, Calibrate: s.observeTTFTCalibration,
	})
}
