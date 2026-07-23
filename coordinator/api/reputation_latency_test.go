package api

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestContentLatency verifies the dispatch-side measurement uses the first
// CONTENT chunk only. A provider that emits a fast role-only / lifecycle
// preamble then stalls (FirstChunkAt set, FirstContentAt zero) must NOT look
// responsive: with no content there is no sample. It also returns 0 when the
// timing is otherwise incomplete.
func TestContentLatency(t *testing.T) {
	base := time.Now()
	cases := []struct {
		name   string
		timing *registry.RequestTiming
		want   time.Duration
	}{
		{
			name: "measures to first content",
			timing: &registry.RequestTiming{
				DispatchedAt:   base,
				FirstChunkAt:   base.Add(10 * time.Millisecond), // held preamble — ignored
				FirstContentAt: base.Add(500 * time.Millisecond),
			},
			want: 500 * time.Millisecond,
		},
		{
			name: "preamble only, no content -> no sample (does NOT use FirstChunkAt)",
			timing: &registry.RequestTiming{
				DispatchedAt: base,
				FirstChunkAt: base.Add(10 * time.Millisecond),
			},
			want: 0,
		},
		{name: "nil timing", timing: nil, want: 0},
		{name: "no dispatch timestamp", timing: &registry.RequestTiming{FirstContentAt: base}, want: 0},
		{name: "dispatched but no chunk (parked/disconnect)", timing: &registry.RequestTiming{DispatchedAt: base}, want: 0},
	}
	for _, c := range cases {
		if got := contentLatency(c.timing); got != c.want {
			t.Errorf("%s: contentLatency = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestAdjustLatencyForPrefill verifies the prefill normalization: the
// prompt-size-dependent prefill (promptTokens / prefillTPS) is removed from the
// raw latency using the provider's own rate, so long prompts don't make a
// provider look slow.
func TestAdjustLatencyForPrefill(t *testing.T) {
	cases := []struct {
		name         string
		raw          time.Duration
		promptTokens int
		prefillTPS   float64
		want         time.Duration
	}{
		{
			name:         "subtracts prompt-size prefill at the provider's own rate",
			raw:          1200 * time.Millisecond,
			promptTokens: 4000,
			prefillTPS:   4000, // 4000 tokens / 4000 tps = 1s of expected prefill
			want:         200 * time.Millisecond,
		},
		{
			name:         "no prefill rate leaves the raw latency",
			raw:          1200 * time.Millisecond,
			promptTokens: 4000,
			prefillTPS:   0,
			want:         1200 * time.Millisecond,
		},
		{
			name:         "no prompt tokens leaves the raw latency",
			raw:          500 * time.Millisecond,
			promptTokens: 0,
			prefillTPS:   4000,
			want:         500 * time.Millisecond,
		},
		{
			name:         "prefill exceeding latency yields no sample",
			raw:          100 * time.Millisecond,
			promptTokens: 10000,
			prefillTPS:   1000, // 10s expected prefill >> 100ms latency
			want:         0,
		},
		{name: "zero raw yields no sample", raw: 0, want: 0},
	}
	for _, c := range cases {
		if got := adjustLatencyForPrefill(c.raw, c.promptTokens, c.prefillTPS); got != c.want {
			t.Errorf("%s: adjustLatencyForPrefill = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestOnlyActualCacheParticipationSuppressesReputationLatency(t *testing.T) {
	plain := &registry.PendingRequest{Timing: &registry.RequestTiming{}}
	if !shouldRecordReputationLatency(plain, "data: content") {
		t.Fatal("ordinary content attempt should record reputation latency")
	}
	cacheDisabled := &registry.PendingRequest{
		Timing: &registry.RequestTiming{},
		CachePlan: registry.CachePlan{
			ModelAggregateHash: "expected",
			PromptContractID:   "contract",
			CacheScope:         "scope",
			PromptTokenCount:   64,
			Boundaries:         []protocol.PrefixCacheAnchor{{TokenCount: 64, ChainHash: strings.Repeat("a", 64)}},
		},
	}
	if !shouldRecordReputationLatency(cacheDisabled, "data: content") {
		t.Fatal("route-derived but cache-disabled attempt lost reputation latency")
	}

	reg := registry.New(quietLogger())
	if err := reg.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode:            registry.CacheRoutingOn,
		ActivationPct:   100,
		TTL:             time.Minute,
		MaxHolders:      4,
		MaxDiscountMs:   1000,
		MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "model", WeightHash: "expected"}})
	provider := &registry.Provider{
		ID:                  "provider",
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{
			"model": {
				ModelID: "model", ModelAggregateHash: "expected",
				PromptContractID: "contract", BlockSize: 64,
				CacheEpoch: "epoch", Enabled: true, Ready: true,
			},
		},
		Models: []protocol.ModelInfo{{ID: "model", WeightHash: "expected"}},
	}
	cached := &registry.PendingRequest{
		RequestID:   "cached-attempt",
		Model:       "model",
		ConsumerKey: "account",
		Timing:      &registry.RequestTiming{},
		CachePlan: registry.CachePlan{
			ModelAggregateHash: "expected",
			PromptContractID:   "contract",
			CacheScope:         "scope",
			PromptTokenCount:   64,
			Boundaries:         []protocol.PrefixCacheAnchor{{TokenCount: 64, ChainHash: strings.Repeat("a", 64)}},
		},
	}
	if err := reg.PrepareCacheAttempt(cached, provider); err != nil {
		t.Fatal(err)
	}
	if !cached.CacheRoutingParticipates() {
		t.Fatal("verified cache attempt was not marked participating")
	}
	if shouldRecordReputationLatency(cached, "data: content") {
		t.Fatal("cache-participating attempt recorded full-prefill reputation latency")
	}
}
