package registry_test

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Mixed provider/coordinator versions may serve normally, but cannot earn a
// cache credit or affinity preference from the other normalization contract.
func TestNormalizationVersionMismatchFallsBackToOrdinaryServing(t *testing.T) {
	var corpus struct {
		Vectors []struct {
			Artifacts  []promptcontract.Artifact `json:"artifacts"`
			LegacyV3ID string                    `json:"legacy_v3_prompt_contract_id"`
			LegacyV6ID string                    `json:"legacy_v6_prompt_contract_id"`
		} `json:"vectors"`
	}
	data, err := os.ReadFile("../../../fixtures/prompt-contract/v1/contract_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatal(err)
	}
	if len(corpus.Vectors) != 1 {
		t.Fatal("expected the shared contract vector")
	}
	vector := corpus.Vectors[0]
	currentID, err := promptcontract.ContractID(vector.Artifacts, promptcontract.CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	for _, legacyID := range []string{vector.LegacyV3ID, vector.LegacyV6ID} {
		if legacyID == "" || legacyID == currentID {
			t.Fatal("missing or unfenced legacy normalization identity")
		}
		for _, oldCoordinator := range []bool{false, true} {
			r, _, capability := newCacheObservationFixture(t)
			r.Disconnect("provider-a")
			capability.PromptContractID = legacyID
			plan := r.plans.bind(exactTestPlan(exactTestAnchor(2, "c")))
			plan.PromptContractID = currentID
			if oldCoordinator {
				capability.PromptContractID, plan.PromptContractID = currentID, legacyID
			}
			p := checkpointPricingProvider(t, r.Registry, "mixed-version", capability)
			if production.CapabilityMatchesPlan(capability, plan) {
				t.Fatal("cross-version cache match")
			}
			matching := plan
			matching.PromptContractID = capability.PromptContractID
			if !production.CapabilityMatchesPlan(capability, matching) {
				t.Fatal("same-version positive control")
			}
			repeated := plan.RepeatedPrefixTokens
			plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now())
			plan.ObserveRouteDemand(r.plans.generation, r.demand, r.routeKey, time.Now())
			plan.RepeatedPrefixTokens = repeated
			pr := &production.PendingRequest{RequestID: "mixed-normalization", Model: "model", CachePlan: plan,
				EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128}
			chosen, decision := r.ReserveProviderEx("model", pr)
			if chosen != p {
				t.Fatalf("normalization mismatch blocked ordinary serving: %+v", decision)
			}
			if decision.SelectionPath == production.SelectionPrefixAffinity || decision.CacheDiscountMs != 0 ||
				decision.CacheTier != "" || pr.CacheSelectionSelected {
				t.Fatalf("normalization mismatch earned cache credit: %+v", decision)
			}
			p.RemovePending(pr.RequestID)
		}
	}
}
