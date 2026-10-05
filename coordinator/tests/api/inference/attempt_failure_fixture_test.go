package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Retain the actual normalized terminal evidence and controller decisions that
// dispatch consumes; this fixture contains no retry or outcome implementation.
type attemptFailureCase struct {
	policy   *retry.Controller
	terminal retry.AttemptFailure
	decision retry.Decision
	model    string
}

func newAttemptFailureCase(t *testing.T, model string, context int) *attemptFailureCase {
	t.Helper()
	s, _ := testServer(t)
	return &attemptFailureCase{model: model, policy: retry.New(retry.Config{Model: model, ModelContext: context, Observation: s.observation})}
}

func (c *attemptFailureCase) providerError(p *registry.Provider, msg protocol.InferenceErrorMessage) {
	c.terminal = retry.ProviderFailure(p, c.model, msg)
}

func (c *attemptFailureCase) coordinatorError(text string, code int) {
	c.terminal = retry.CoordinatorFailure(text, code)
}

func (c *attemptFailureCase) stopFailover() bool {
	c.decision = c.policy.Decide(c.terminal.Message, c.terminal.ProviderBudget)
	return c.decision.Stop
}

func (c *attemptFailureCase) loser(p *registry.Provider, msg protocol.InferenceErrorMessage) {
	evidence := retry.ProviderFailure(p, c.model, msg)
	c.decision, _ = c.policy.RecordLoser(evidence.Message, evidence.ProviderBudget)
}

func (c *attemptFailureCase) routeOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return c.terminal.RouteOutcome(pr)
}
