package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A proof mismatch received over the provider WebSocket fences the capability
// for a bounded window: receipts inside it are rejected as capability_fenced,
// /v1/cache/status counts the window, and a valid proof after it is accepted.
func TestProofFenceLiftsOverProviderWire(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	configureCachePreparationTest(t, reg)
	base := time.Now()
	var offset atomic.Int64
	reg.SetCacheRoutingClockForTest(func() time.Time { return base.Add(time.Duration(offset.Load())) })
	httpServer := httptest.NewServer(srv.Handler())
	defer httpServer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	capability := cacheEligibilityV2Capability("model")
	writeProviderJSON(t, ctx, conn, protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift",
		Models:              []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}},
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	plan := cachePreparationPlanForTest(t, reg, capability)
	var provider *registry.Provider
	waitCacheCondition(t, func() bool {
		ids := reg.ProviderIDs()
		if len(ids) != 1 {
			return false
		}
		provider = reg.GetProvider(ids[0])
		return provider != nil
	})
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	seq := uint64(0)
	sendLookup := func(id, hash string) {
		t.Helper()
		pr := &registry.PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
		if err := reg.PrepareCacheAttempt(pr, provider); err != nil {
			t.Fatal(err)
		}
		nonce := providerInferenceWireMessage(id, "ephemeral", "ciphertext", pr).CacheReceiptNonce
		if nonce == "" {
			t.Fatalf("attempt %s did not prepare", id)
		}
		seq++
		writeProviderJSON(t, ctx, conn, protocol.PrefixCacheLookupV2Message{
			Type: protocol.TypePrefixCacheLookupV2, RequestID: id, CacheReceiptNonce: nonce,
			ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
			PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
			CacheSeq:     seq,
			PromptAnchor: protocol.PrefixCacheAnchor{TokenCount: prompt.TokenCount, ChainHash: hash},
			Outcome:      "miss_absent", Tier: "ssd", StageMs: 1,
		})
	}
	receipts := func(outcome, reason string) int64 {
		return srv.Metrics().Snapshot().Counters[metricKey("exact_cache_receipt_total", []MetricLabel{
			{"type", "lookup_v2"}, {"outcome", outcome}, {"reason", reason},
		})]
	}
	// The public endpoint caches for a second; poll through it so the
	// projection itself is what is asserted.
	waitStatus := func(want func(registry.CacheRoutingLifecycleStatus) bool) registry.CacheRoutingLifecycleStatus {
		t.Helper()
		var status ExactCacheStatus
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			response, err := http.Get(httpServer.URL + "/v1/cache/status")
			if err != nil {
				t.Fatal(err)
			}
			err = json.NewDecoder(response.Body).Decode(&status)
			_ = response.Body.Close()
			if err != nil {
				t.Fatal(err)
			}
			if want(status.Lifecycle) {
				return status.Lifecycle
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("cache status never reached the wanted lifecycle: %+v", status.Lifecycle)
		return status.Lifecycle
	}

	sendLookup("mismatch", strings.Repeat("d", 64))
	waitCacheCondition(t, func() bool { return receipts("rejected", "prompt_anchor_mismatch") == 1 })
	waitStatus(func(s registry.CacheRoutingLifecycleStatus) bool {
		return s.FencesApplied == 1 && s.FencesExpired == 0 && s.FencedCapabilities == 1
	})

	sendLookup("fenced", prompt.ChainHash)
	waitCacheCondition(t, func() bool { return receipts("rejected", "capability_fenced") == 1 })

	offset.Store(int64(61 * time.Second))
	sendLookup("accepted", prompt.ChainHash)
	waitCacheCondition(t, func() bool { return receipts("accepted", "accepted") == 1 })
	status := waitStatus(func(s registry.CacheRoutingLifecycleStatus) bool {
		return s.FencesApplied == 1 && s.FencesExpired == 1 && s.FencedCapabilities == 0
	})
	if status.HolderRemoved["proof_mismatch"] != 0 {
		t.Fatalf("mismatch with no holders reported removals: %+v", status.HolderRemoved)
	}
}
