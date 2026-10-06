package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentQuoteShapeSurvivesPlannerInvalidation(t *testing.T) {
	forecast := firstcontent.NewForecast(estimate.NewContextCalibration(),

		nil)
	plan := registry.CachePlan{PromptTokenCount: 800}
	if got := forecast.PromptWork(nil, "gpt-oss-20b", nil, 1000, plan.PromptTokenCount); got != 1300 {
		t.Fatalf("probe work=%d, want calibrated fallback envelope", got)
	}
	plan.PromptTokenCount = 2000
	if got := forecast.PromptWork(nil, "gpt-oss-20b", nil, 1000, plan.PromptTokenCount); got != 2000 {
		t.Fatalf("probe work=%d, want larger exact prompt count", got)
	}
}

func TestExemptHedgeAdvisoryForecastDoesNotInstallDeadline(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "exempt-hedge-forecast"
	provider := planWiringProvider(t, s.registry, "exempt-spare", model, 0)
	reportIdleFirstContentEvidence(s.registry, provider.ID, model)
	forecast := firstcontent.NewForecast(estimate.NewContextCalibration(),

		nil)
	pr := &registry.PendingRequest{RequestID: "exempt-hedge", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 64}
	forecast.Configure(pr, model, 500, 0, true)
	winner, decision := s.registry.ReserveProviderEx(model, pr)
	if winner == nil || decision.FirstContent.Status != registry.FirstContentFeasible {
		t.Fatalf("credible exempt hedge unavailable: %+v", decision)
	}
	defer winner.RemovePending(pr.RequestID)
	if !pr.FirstContentDeadline.IsZero() || pr.MaxTTFTMs != 0 || !pr.RefreshFirstContentBudget(time.Now().Add(time.Hour)) {
		t.Fatal("advisory forecast installed a deadline on an exempt request")
	}
}

func TestExemptPredictiveRetryCanRecoverWithoutInstallingDeadline(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "exempt-predictive-retry"
	provider := planWiringProvider(t, s.registry, "exempt-fresh", model, 0)
	excluded := map[string]struct{}{}
	forecast := firstcontent.NewForecast(estimate.NewContextCalibration(),

		func(id string) { excluded[id] = struct{}{} })
	ordinary := &registry.PendingRequest{RequestID: "ordinary", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 64}
	forecast.Configure(ordinary, model, 500, 0, false)
	if ordinary.FirstContentPlanningHorizon != 0 {
		t.Fatal("ordinary exempt primary acquired an advisory horizon")
	}
	forecast.Refused(&registry.Provider{ID: "refused-a"})
	forecast.Refused(&registry.Provider{ID: "refused-b"})
	reportIdleFirstContentEvidence(s.registry, provider.ID, model)
	pr := &registry.PendingRequest{RequestID: "exempt-retry", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 64}
	forecast.Configure(pr, model, 500, 0, false)
	winner, decision := s.registry.ReserveProviderEx(model, pr)
	if winner == nil || decision.FirstContent.Status != registry.FirstContentFeasible || pr.Hedge {
		t.Fatalf("fresh exempt retry unavailable: %+v", decision)
	}
	defer winner.RemovePending(pr.RequestID)
	if !pr.FirstContentDeadline.IsZero() || pr.MaxTTFTMs != 0 || !pr.RefreshFirstContentBudget(time.Now().Add(time.Hour)) {
		t.Fatal("advisory retry forecast installed a deadline on an exempt request")
	}
}
