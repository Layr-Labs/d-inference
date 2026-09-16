package ingress

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

// FirstContentDeadline returns this server's request-absolute first-content
// budget for a concrete model. The ordinary base is instance-owned so
// production-like E2E servers can use the production value without mutating
// concurrent unit tests. Exact-model overrides and the fixed 1ms/token slope
// are centralized in modelpolicy.
func (s *Controller) FirstContentDeadline(model string, estimatedPromptTokens int) time.Duration {
	base := s.deps.FirstContentDeadlineBase()
	if base <= 0 {
		base = dispatch.DefaultFirstContentDeadlineBase
	}
	return modelpolicy.CoordinatorFirstContentDeadline(model, estimatedPromptTokens, base)
}
