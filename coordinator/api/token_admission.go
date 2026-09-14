package api

import (
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
)

// SetTokenLimiters configures the per-account input/output token-per-minute
// limiters for the consumer and service tiers. Pass nil for a tier to disable
// token limiting for it.
func (s *Server) SetTokenLimiters(consumer, service *ratelimit.TokenLimiter) {
	s.consumerTokenLimiter = consumer
	s.serviceTokenLimiter = service
}

func (s *Server) SetOutputAdmissionEstimator(estimator *ratelimit.OutputAdmissionEstimator) {
	s.outputAdmissionEstimator = estimator
}

// SetKeyLimiters configures the per-key (variable-rate) RPM and ITPM/OTPM
// limiters used for per-key overrides. Pass nil to disable per-key limiting.
func (s *Server) SetKeyLimiters(rpm *ratelimit.Limiter, tokens *ratelimit.KeyTokenLimiter) {
	s.keyRPMLimiter = rpm
	s.keyTokenLimiter = tokens
}
