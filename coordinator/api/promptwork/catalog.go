package promptwork

import (
	_ "embed"

	calibration "github.com/eigeninference/d-inference/coordinator/internal/promptwork/calibration"
)

// reviewedCatalog is release data copied from qualified, independently held-out
// corpus receipts. These stress-corpus coefficients apply only to the measured
// identity and shape domains; they do not describe production traffic medians.
//
//go:embed catalog/prompt_counts.json
var reviewedCatalog []byte

var reviewedCalibrations = calibration.Load(reviewedCatalog)
