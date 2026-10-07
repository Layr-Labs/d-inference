package observation_test

import (
	"encoding/json"
	"testing"

	profile "github.com/eigeninference/d-inference/coordinator/internal/observation/profile"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDecisionJSONPreservesFirstContentEvidence(t *testing.T) {
	scan := registry.FirstContentEstimate{
		Status: registry.FirstContentFeasible, ExpectedMs: 400, ConservativeMs: 1500,
		BudgetMs: 3000, CapacityAgeMs: 100, PerformanceAgeMs: 200,
		PromptTokens: 1000, CachedTokens: 800, RestoreMs: 25, ServiceMs: 500,
	}
	committed := scan
	committed.BudgetMs = 2200
	committed.CapacityAgeMs = 900
	unknown := registry.FirstContentEstimate{
		Status: registry.FirstContentUnknown, Reason: "performance_age_unknown_or_stale",
		ExpectedMs: 600, ConservativeMs: 2000, CapacityAgeMs: 10, PerformanceAgeMs: -1,
	}
	d := registry.RoutingDecision{
		ProviderID: "winner", FirstContent: committed,
		Top: [4]registry.CandidateSummary{
			{ProviderID: "winner", Present: true, FirstContent: scan},
			{ProviderID: "unknown", Present: true, FirstContent: unknown},
		},
	}
	raw, _ := profile.DecisionJSON(d)
	var got []profile.CandidateJSON
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].FirstContent == nil || *got[0].FirstContent != committed {
		t.Fatalf("winner must retain current commit evidence, got %s", raw)
	}
	if got[1].FirstContent == nil || *got[1].FirstContent != unknown {
		t.Fatalf("unknown is distinct from zero-latency feasible evidence: %s", raw)
	}
	if d.Top[0].FirstContent != scan {
		t.Fatal("serialization mutated immutable scan context")
	}
}

func TestDecisionJSONOmitsAbsentFirstContentEvidence(t *testing.T) {
	raw, _ := profile.DecisionJSON(registry.RoutingDecision{
		Top: [4]registry.CandidateSummary{{ProviderID: "legacy", Present: true}},
	})
	var got []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("unexpected candidates: %s", raw)
	}
	if _, present := got[0]["first_content"]; present {
		t.Fatalf("absent forecast must not masquerade as zero-latency evidence: %s", raw)
	}
}
