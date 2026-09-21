package registry

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Mixed provider/coordinator versions may serve normally, but cannot earn a
// cache credit or affinity preference from the other normalization contract.
func TestNormalizationVersionMismatchFallsBackToOrdinaryServing(t *testing.T) {
	var corpus struct {
		Vectors []struct {
			Artifacts []promptcontract.Artifact `json:"artifacts"`
			LegacyID  string                    `json:"legacy_v3_prompt_contract_id"`
		} `json:"vectors"`
	}
	data, err := os.ReadFile("../../fixtures/prompt-contract/v1/contract_vectors.json")
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
	for _, oldCoordinator := range []bool{false, true} {
		r, _, capability := exactTestRegistry(t)
		removeTestProvider(r, "provider-a")
		capability.PromptContractID = vector.LegacyID
		plan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(2, "c")))
		plan.PromptContractID = currentID
		if oldCoordinator {
			capability.PromptContractID, plan.PromptContractID = currentID, vector.LegacyID
		}
		p := checkpointTestProvider(t, r, "mixed-version", capability)
		if capabilityMatchesPlan(capability, plan) {
			t.Fatal("cross-version cache match")
		}
		matching := plan
		matching.PromptContractID = capability.PromptContractID
		if !capabilityMatchesPlan(capability, matching) {
			t.Fatal("same-version positive control")
		}
		plan.affinityKey = "repeated-prefix"
		pr := &PendingRequest{RequestID: "mixed-normalization", Model: "model", CachePlan: plan,
			EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128}
		chosen, decision := r.ReserveProviderEx("model", pr)
		if chosen != p {
			t.Fatalf("normalization mismatch blocked ordinary serving: %+v", decision)
		}
		if decision.SelectionPath == SelectionPrefixAffinity || decision.CacheDiscountMs != 0 ||
			decision.CacheTier != "" || pr.CacheSelectionSelected {
			t.Fatalf("normalization mismatch earned cache credit: %+v", decision)
		}
		p.RemovePending(pr.RequestID)
	}
}
