package promptcontract

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestProductionPlansConsumeSharedTokenVectors(t *testing.T) {
	type fixtureCase struct {
		ID       string   `json:"id"`
		ScopeID  string   `json:"scope_id"`
		TokenIDs []uint32 `json:"token_ids"`
		Plan     struct {
			PromptContractID      string     `json:"prompt_contract_id"`
			PromptTokenCount      uint32     `json:"prompt_token_count"`
			BlockBoundaries       []Boundary `json:"block_boundaries"`
			LastCompleteBlockHash *string    `json:"last_complete_block_hash"`
		} `json:"plan"`
	}
	var corpus struct {
		SchemaVersion uint32 `json:"schema_version"`
		Models        []struct {
			ModelID              string        `json:"model_id"`
			PromptContractID     string        `json:"prompt_contract_id"`
			CacheRoutingEligible bool          `json:"cache_routing_eligible"`
			IneligibilityReason  string        `json:"ineligibility_reason"`
			Cases                []fixtureCase `json:"cases"`
		} `json:"models"`
	}
	encoded, err := os.ReadFile(filepath.Join(
		"..", "..", "fixtures", "prompt-contract", "v1", "production_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	if corpus.SchemaVersion != 1 || len(corpus.Models) == 0 {
		t.Fatal("production prompt vector inventory is empty or unsupported")
	}
	models := make(map[string]bool, len(corpus.Models))
	for _, model := range corpus.Models {
		if model.ModelID == "" || models[model.ModelID] {
			t.Fatalf("invalid or duplicate production model %q", model.ModelID)
		}
		models[model.ModelID] = true
		if !model.CacheRoutingEligible {
			if model.IneligibilityReason != "dynamic_time" || len(model.Cases) != 0 {
				t.Fatalf("invalid ineligible production model %q", model.ModelID)
			}
			continue
		}
		if model.IneligibilityReason != "" || len(model.Cases) == 0 {
			t.Fatalf("invalid eligible production model %q", model.ModelID)
		}
		cases := make(map[string]bool, len(model.Cases))
		for _, fixture := range model.Cases {
			if fixture.ID == "" || cases[fixture.ID] {
				t.Fatalf("invalid or duplicate case %q for %q", fixture.ID, model.ModelID)
			}
			cases[fixture.ID] = true
			if fixture.Plan.PromptContractID != model.PromptContractID ||
				fixture.Plan.PromptTokenCount != uint32(len(fixture.TokenIDs)) {
				t.Fatalf("plan identity/count mismatch for %s/%s", model.ModelID, fixture.ID)
			}
			var parent [32]byte
			eligible := (len(fixture.TokenIDs) - 1) / int(BlockSize)
			if len(fixture.TokenIDs) == 0 {
				eligible = 0
			}
			if len(fixture.Plan.BlockBoundaries) != eligible {
				t.Fatalf("boundary count mismatch for %s/%s", model.ModelID, fixture.ID)
			}
			for index := range eligible {
				start := index * int(BlockSize)
				hash, err := BlockHash(
					[]byte(model.PromptContractID),
					[]byte(fixture.ScopeID),
					parent,
					uint32(index),
					fixture.TokenIDs[start:start+int(BlockSize)],
				)
				if err != nil {
					t.Fatal(err)
				}
				expected := hex.EncodeToString(hash[:])
				if fixture.Plan.BlockBoundaries[index].TokenCount != uint32(start)+BlockSize ||
					fixture.Plan.BlockBoundaries[index].ChainHash != expected {
					t.Fatalf("boundary mismatch for %s/%s block %d", model.ModelID, fixture.ID, index)
				}
				parent = hash
			}
			if eligible == 0 {
				if fixture.Plan.LastCompleteBlockHash != nil {
					t.Fatalf("unexpected last boundary for %s/%s", model.ModelID, fixture.ID)
				}
			} else if fixture.Plan.LastCompleteBlockHash == nil ||
				*fixture.Plan.LastCompleteBlockHash != hex.EncodeToString(parent[:]) {
				t.Fatalf("last boundary mismatch for %s/%s", model.ModelID, fixture.ID)
			}
		}
	}

	var raw struct {
		Models []struct {
			Cases []struct {
				Plan map[string]json.RawMessage `json:"plan"`
			} `json:"cases"`
		} `json:"models"`
	}
	if err := json.Unmarshal(encoded, &raw); err != nil {
		t.Fatal(err)
	}
	for _, model := range raw.Models {
		for _, fixture := range model.Cases {
			if _, exists := fixture.Plan["normalized_body"]; exists {
				t.Fatal("sidecar plan fixture exposed normalized_body")
			}
		}
	}
}
