package ratelimit

import "math"

// OutputAdmissionEstimator converts bounded max_tokens into the output-token
// charge used for service-account admission. Billing still reserves and settles
// against the full bounded max_tokens path; this only affects OTPM.
type OutputAdmissionEstimator struct {
	cfg OutputAdmissionEstimatorConfig
}

func NewOutputAdmissionEstimator(cfg OutputAdmissionEstimatorConfig) *OutputAdmissionEstimator {
	if !cfg.Enabled {
		return nil
	}
	if cfg.Fraction <= 0 || cfg.Fraction > 1 {
		cfg.Fraction = 1
	}
	if cfg.Floor < 0 {
		cfg.Floor = 0
	}
	if cfg.Ceiling < 0 {
		cfg.Ceiling = 0
	}
	return &OutputAdmissionEstimator{cfg: cfg}
}

func (e *OutputAdmissionEstimator) Estimate(boundedMaxTokens int) (int, bool) {
	if e == nil {
		return boundedMaxTokens, false
	}
	if boundedMaxTokens <= 0 {
		return 0, true
	}
	estimate := int(math.Ceil(float64(boundedMaxTokens) * e.cfg.Fraction))
	if estimate < e.cfg.Floor {
		estimate = e.cfg.Floor
	}
	if e.cfg.Ceiling > 0 && estimate > e.cfg.Ceiling {
		estimate = e.cfg.Ceiling
	}
	if estimate > boundedMaxTokens {
		estimate = boundedMaxTokens
	}
	if estimate < 0 {
		return 0, true
	}
	return estimate, true
}

func (e *OutputAdmissionEstimator) Config() OutputAdmissionEstimatorConfig {
	if e == nil {
		return OutputAdmissionEstimatorConfig{}
	}
	return e.cfg
}
