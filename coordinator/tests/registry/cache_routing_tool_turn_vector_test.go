package registry_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestGemmaToolTurnVectorCreatesExactHolderMatch(t *testing.T) {
	var vectors struct {
		Models []struct {
			ModelID          string `json:"model_id"`
			PromptContractID string `json:"prompt_contract_id"`
			Cases            []struct {
				ID   string `json:"id"`
				Plan struct {
					PromptTokenCount int                          `json:"prompt_token_count"`
					BlockBoundaries  []protocol.PrefixCacheAnchor `json:"block_boundaries"`
				} `json:"plan"`
			} `json:"cases"`
		} `json:"models"`
	}
	encoded, err := os.ReadFile(filepath.Join(
		"..", "..", "..", "fixtures", "prompt-contract", "v1", "production_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &vectors); err != nil {
		t.Fatal(err)
	}

	var contractID string
	var promptTokenCount int
	var boundaries []protocol.PrefixCacheAnchor
	for _, model := range vectors.Models {
		if model.ModelID != "gemma-4-26b" {
			continue
		}
		contractID = model.PromptContractID
		for _, fixture := range model.Cases {
			if fixture.ID == "gemma_tool_turn" {
				promptTokenCount = fixture.Plan.PromptTokenCount
				boundaries = fixture.Plan.BlockBoundaries
				break
			}
		}
	}
	if contractID == "" || len(boundaries) < 2 {
		t.Fatalf("Gemma tool-turn vector lacks exact-routing boundaries: contract=%q boundaries=%d",
			contractID, len(boundaries))
	}

	r, f := newCheckpointPricingFixture(t)
	provider := r.GetProvider("provider-a")
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	capability.PromptContractID = contractID
	provider.Mu().Lock()
	provider.PrefixCacheV2Models["model"] = capability
	provider.Mu().Unlock()
	plan := f.plans.bind(production.CachePlan{
		ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID:   contractID,
		CacheScope:         "gemma-tool-turn",
		PromptTokenCount:   promptTokenCount,
		Boundaries:         boundaries,
	})
	request := &production.PendingRequest{
		RequestID: "gemma-tool-turn-seed",
		Model:     "model",
		CachePlan: plan,
	}
	if err := r.PrepareCacheAttempt(request, provider); err != nil {
		t.Fatal(err)
	}

	longest := boundaries[len(boundaries)-1]
	lookup := &protocol.PrefixCacheLookupV2Message{
		RequestID: request.RequestID, CacheReceiptNonce: request.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: contractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: longest, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("Gemma tool-turn lookup proof was rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		RequestID: request.RequestID, CacheReceiptNonce: request.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: contractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{longest},
		ExpectedPrefillTokensSaved: longest.TokenCount,
		StageMs:                    2,
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("Gemma tool-turn ready proof was rejected")
	}

	hints := f.hints(plan, time.Now())
	hint, ok := hints[provider.ID]
	if !ok || hint.CachedTokens != longest.TokenCount ||
		hint.PrefillTokensSaved != longest.TokenCount {
		t.Fatalf("Gemma tool-turn exact holder did not match: hint=%+v present=%t", hint, ok)
	}
}
