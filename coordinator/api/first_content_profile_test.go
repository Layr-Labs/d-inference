package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentProfileRetainsForecastAndAlternative(t *testing.T) {
	d := registry.RoutingDecision{
		ProviderID: "winner", FirstContentMode: registry.FirstContentRoutingShadow,
		FirstContentFeasibleCount: 2,
		FirstContentBestFeasible:  registry.CandidateSummary{ProviderID: "alternative", FirstContent: registry.FirstContentEstimate{Status: "feasible", PredictedMs: 5000}},
		Top: [4]registry.CandidateSummary{{ProviderID: "winner", Present: true, TTFTMs: 8000,
			FirstContent: registry.FirstContentEstimate{Status: "infeasible", PredictedMs: 38000, BudgetMs: 22000, PromptTokens: 16000}}},
	}
	raw, _ := decisionJSON(d)
	var rows []candidateJSON
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].TTFTMs != 8000 || rows[0].FirstContent == nil ||
		rows[0].FirstContent.PredictedMs != 38000 || rows[0].FirstContent.BudgetMs != 22000 ||
		rows[0].FirstContentMode != "shadow" || rows[0].FirstContentFeasibleCount != 2 ||
		rows[0].FirstContentBestFeasibleID != "alternative" || rows[0].FirstContentBestFeasibleMs != 5000 {
		t.Fatalf("forecast or independent ranking estimate lost: %s", raw)
	}
	d.FirstContentMode = "off"
	d.Top[0].FirstContent = registry.FirstContentEstimate{}
	raw, _ = decisionJSON(d)
	if strings.Contains(string(raw), "first_content") {
		t.Fatalf("off mode changed persisted shape: %s", raw)
	}
}
