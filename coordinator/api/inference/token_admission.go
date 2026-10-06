package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/tokenadmission"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) tokenAdmissionPolicy() tokenadmission.Policy {
	return tokenadmission.Policy{
		Consumer: s.consumerTokenLimiter, Service: s.serviceTokenLimiter,
		Keys: s.keyTokenLimiter, OutputEstimator: s.outputAdmissionEstimator,
		Access: s.access, Observation: s.observation,
	}
}

func (s *Owner) applyTokenRateLimit(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) bool {
	return s.tokenAdmissionPolicy().Allow(w, r, inputTokens, outputTokens)
}

func (s *Owner) applyTokenRateLimitWithAdmission(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) (registry.TokenAdmission, bool) {
	return s.tokenAdmissionPolicy().Admit(w, r, inputTokens, outputTokens)
}

func (s *Owner) reconcileOutputAdmission(pr *registry.PendingRequest, actualOutputTokens int) {
	s.tokenAdmissionPolicy().Reconcile(pr, actualOutputTokens)
}
