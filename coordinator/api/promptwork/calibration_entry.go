package promptwork

import (
	calibration "github.com/eigeninference/d-inference/coordinator/internal/promptwork/calibration"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func Calibrated(model, artifact, contract string, estimate int, hasTools bool, shape calibration.Shape) *protocol.PromptWork {
	return calibration.Calibrate(reviewedCalibrations, model, artifact, contract, estimate, hasTools, shape)
}

// HasCalibrations avoids parsing a body when there is no reviewed fallback.
func HasCalibrations() bool { return len(reviewedCalibrations) > 0 }
