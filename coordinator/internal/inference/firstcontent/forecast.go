package firstcontent

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const RefusalRefreshThreshold = 2
const ExemptPlanningHorizon = 600 * time.Second

type RefusalDecision struct {
	Count      int
	FreshAfter time.Time
}

// Forecast owns request-local refusal deduplication and the evidence cutoff.
// Physical token reservations and billing estimates remain separate inputs.
type Forecast struct {
	calibration *estimate.ContextCalibration
	exclude     func(string)
	refused     map[string]struct{}
	count       int
	freshAfter  time.Time
}

func NewForecast(calibration *estimate.ContextCalibration, exclude func(string)) *Forecast {
	return &Forecast{calibration: calibration, exclude: exclude}
}

func (f *Forecast) Refused(provider *registry.Provider) RefusalDecision {
	if provider != nil {
		if f.refused == nil {
			f.refused = make(map[string]struct{})
		}
		if _, seen := f.refused[provider.ID]; seen {
			return RefusalDecision{Count: f.count, FreshAfter: f.freshAfter}
		}
		f.refused[provider.ID] = struct{}{}
		f.exclude(provider.ID)
	}
	f.count++
	if f.count >= RefusalRefreshThreshold {
		f.freshAfter = time.Now()
	}
	return RefusalDecision{Count: f.count, FreshAfter: f.freshAfter}
}

func (f *Forecast) Configure(pr *registry.PendingRequest, model string, prompt int, deadline time.Duration, hedge bool) {
	pr.FirstContentPromptTokens = f.calibration.ContextPromptTokens(model, prompt)
	pr.RequireFreshFeasible = f.count >= RefusalRefreshThreshold
	pr.RequireFreshFeasibleAfter = f.freshAfter
	pr.Hedge = hedge
	if (hedge || pr.RequireFreshFeasible) && deadline <= 0 {
		pr.FirstContentPlanningHorizon = ExemptPlanningHorizon
	}
}

func (f *Forecast) PromptWork(r *http.Request, model string, body []byte, prompt, exactPlanTokens int) int {
	tokens := max(exactPlanTokens, f.calibration.ContextPromptTokens(model, prompt))
	if r != nil {
		if work := promptwork.FromContext(r.Context(), model, body); work != nil && work.IsQualifiedFor(work.ModelArtifactHash, work.PromptContractID) {
			tokens = max(tokens, work.UpperBoundTokens)
		}
	}
	return tokens
}
