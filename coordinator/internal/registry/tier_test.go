package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
)

func TestClassifyTier(t *testing.T) {
	tests := []struct {
		memGB int
		want  protocol.ProviderTier
	}{
		{8, protocol.ProviderTierTiny},   // M2 Air
		{16, protocol.ProviderTierTiny},  // M3 Air, base Mini
		{18, protocol.ProviderTierSmall}, // newer Air bumps
		{24, protocol.ProviderTierSmall}, // mid Air / 24 GB Mini
		{32, protocol.ProviderTierStandard},
		{64, protocol.ProviderTierStandard},
		{128, protocol.ProviderTierStandard},
	}
	for _, tt := range tests {
		got := ClassifyTier(tt.memGB)
		if got != tt.want {
			t.Errorf("ClassifyTier(%d)=%q, want %q", tt.memGB, got, tt.want)
		}
	}
}

func TestPreferredTiersForModelType(t *testing.T) {
	embedTiers := PreferredTiersForModelType("embedding")
	if len(embedTiers) != 2 {
		t.Fatalf("embedding should prefer 2 tiers, got %d", len(embedTiers))
	}
	rerankTiers := PreferredTiersForModelType("rerank")
	if len(rerankTiers) != 2 {
		t.Fatalf("rerank should prefer 2 tiers, got %d", len(rerankTiers))
	}
	textTiers := PreferredTiersForModelType("text")
	if textTiers != nil {
		t.Errorf("text should have no tier preference, got %v", textTiers)
	}
	if PreferredTiersForModelType("") != nil {
		t.Errorf("empty model type should have no tier preference")
	}
}

func TestAllowedTiersForModelType(t *testing.T) {
	allowed := AllowedTiersForModelType("embedding")
	if _, ok := allowed[protocol.ProviderTierTiny]; !ok {
		t.Errorf("embedding should allow tiny")
	}
	if _, ok := allowed[protocol.ProviderTierStandard]; !ok {
		t.Errorf("embedding should allow standard as fallback")
	}
	if AllowedTiersForModelType("text") != nil {
		t.Errorf("text should have no allow filter")
	}
}

// TestEmbeddingRoutingPrefersSmallTier verifies that when the model catalog
// marks a model as embedding/rerank, the scheduler routes the request to a
// tiny/small-tier provider over an idle standard-tier provider — even if the
// standard provider would otherwise score better. This is the core
// "disaggregated compute" guarantee: low-RAM Macs get the embedding work
// so big-RAM Macs stay free for memory-bandwidth-bound decode.
func TestEmbeddingRoutingPrefersSmallTier(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "bge-m3", ModelType: "embedding"},
	})

	// Tiny provider (16 GB Air) — should win.
	tinyMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M3", MemoryGB: 16, MemoryBandwidthGBs: 100},
		Models:   []protocol.ModelInfo{{ID: "bge-m3", ModelType: "embedding"}},
		Backend:  "test",
	}
	tinyP := reg.Register("tiny-prov", nil, tinyMsg)
	tinyP.mu.Lock()
	tinyP.TrustLevel = TrustHardware
	tinyP.RuntimeVerified = true
	tinyP.LastChallengeVerified = time.Now()
	tinyP.mu.Unlock()

	// Standard 128 GB provider — also serves embeddings, much faster, but
	// should NOT win when tiny is available.
	bigMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M4 Max", MemoryGB: 128, MemoryBandwidthGBs: 546},
		Models:   []protocol.ModelInfo{{ID: "bge-m3", ModelType: "embedding"}},
		Backend:  "test",
	}
	bigP := reg.Register("big-prov", nil, bigMsg)
	bigP.mu.Lock()
	bigP.TrustLevel = TrustHardware
	bigP.RuntimeVerified = true
	bigP.LastChallengeVerified = time.Now()
	bigP.mu.Unlock()

	req := &PendingRequest{
		RequestID:          "emb-1",
		Model:              "bge-m3",
		RequestedMaxTokens: 1,
	}
	selected := reg.ReserveProvider("bge-m3", req)
	if selected == nil {
		t.Fatal("no provider selected")
	}
	if selected.ID != tinyP.ID {
		t.Fatalf("expected tiny provider %q to win embedding routing, got %q (tier=%q)",
			tinyP.ID, selected.ID, selected.Tier)
	}
}

// TestEmbeddingFallsBackToBigWhenSmallExhausted verifies that when no
// tiny/small provider is available, embedding requests still route to a
// standard-tier provider rather than failing. The mismatch penalty is
// finite — big providers are a correctness fallback, not blocked.
func TestEmbeddingFallsBackToBigWhenSmallExhausted(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "bge-m3", ModelType: "embedding"},
	})

	bigMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M4 Max", MemoryGB: 128, MemoryBandwidthGBs: 546},
		Models:   []protocol.ModelInfo{{ID: "bge-m3", ModelType: "embedding"}},
		Backend:  "test",
	}
	bigP := reg.Register("big-prov", nil, bigMsg)
	bigP.mu.Lock()
	bigP.TrustLevel = TrustHardware
	bigP.RuntimeVerified = true
	bigP.LastChallengeVerified = time.Now()
	bigP.mu.Unlock()

	req := &PendingRequest{
		RequestID:          "emb-1",
		Model:              "bge-m3",
		RequestedMaxTokens: 1,
	}
	selected := reg.ReserveProvider("bge-m3", req)
	if selected == nil {
		t.Fatal("expected fallback to standard-tier provider, got nil")
	}
	if selected.ID != bigP.ID {
		t.Fatalf("expected big provider %q as fallback, got %q", bigP.ID, selected.ID)
	}
}

// TestTextRoutingHasNoTierPreference confirms that ordinary text decode
// requests are not affected by the tier preference logic — they go to the
// best-scored provider regardless of size.
func TestTextRoutingHasNoTierPreference(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "qwen-9b", ModelType: "text"},
	})

	tinyMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M3", MemoryGB: 16, MemoryBandwidthGBs: 100},
		Models:   []protocol.ModelInfo{{ID: "qwen-9b", ModelType: "text"}},
		Backend:  "test",
	}
	tinyP := reg.Register("tiny-prov", nil, tinyMsg)
	tinyP.mu.Lock()
	tinyP.TrustLevel = TrustHardware
	tinyP.RuntimeVerified = true
	tinyP.LastChallengeVerified = time.Now()
	tinyP.mu.Unlock()

	bigMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M4 Max", MemoryGB: 128, MemoryBandwidthGBs: 546},
		Models:   []protocol.ModelInfo{{ID: "qwen-9b", ModelType: "text"}},
		Backend:  "test",
	}
	bigP := reg.Register("big-prov", nil, bigMsg)
	bigP.mu.Lock()
	bigP.TrustLevel = TrustHardware
	bigP.RuntimeVerified = true
	bigP.LastChallengeVerified = time.Now()
	bigP.mu.Unlock()

	req := &PendingRequest{
		RequestID:          "chat-1",
		Model:              "qwen-9b",
		RequestedMaxTokens: 256,
	}
	selected := reg.ReserveProvider("qwen-9b", req)
	if selected == nil {
		t.Fatal("no provider selected")
	}
	// The big provider has 5.5x the memory bandwidth — for text decode, it
	// should win on cost (faster prefill + decode), not be downgraded by tier.
	if selected.ID != bigP.ID {
		t.Errorf("expected big provider to win text routing on perf, got %q", selected.ID)
	}
}

func TestRegisterAssignsTier(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone

	tinyMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M2", MemoryGB: 16},
		Models:   []protocol.ModelInfo{{ID: "bge"}},
		Backend:  "test",
	}
	tinyP := reg.Register("tiny-prov", nil, tinyMsg)
	if tinyP.Tier != protocol.ProviderTierTiny {
		t.Errorf("16 GB provider tier=%q, want tiny", tinyP.Tier)
	}

	bigMsg := &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "M4 Max", MemoryGB: 128},
		Models:   []protocol.ModelInfo{{ID: "qwen"}},
		Backend:  "test",
	}
	bigP := reg.Register("big-prov", nil, bigMsg)
	if bigP.Tier != protocol.ProviderTierStandard {
		t.Errorf("128 GB provider tier=%q, want standard", bigP.Tier)
	}
}
