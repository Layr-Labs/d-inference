package inference_test

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

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

// cacheReceiptWire drives exact-cache receipts through a real provider
// WebSocket against an in-process coordinator. Plans come from the public
// planner with a synthetic local sidecar; only the clock is injected.
type cacheReceiptWire struct {
	t          *testing.T
	ctx        context.Context
	reg        *registry.Registry
	srv        *serverFixture
	url        string
	conn       *websocket.Conn
	capability protocol.PrefixCacheV2Capability
	plan       registry.CachePlan
	provider   *registry.Provider
	offset     atomic.Int64
	seq        uint64
}

func newCacheReceiptWire(t *testing.T, capability protocol.PrefixCacheV2Capability) *cacheReceiptWire {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	var base time.Time
	w := &cacheReceiptWire{t: t, capability: capability}
	w.reg = registry.NewWithDependencies(logger, registry.Dependencies{Cache: registry.CacheDependencies{
		Now: func() time.Time { return base.Add(time.Duration(w.offset.Load())) },
	}})
	w.srv = newComposedServer(w.reg, memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	configureCachePreparationTest(t, w.reg)
	base = time.Now()
	httpServer := httptest.NewServer(w.srv.Handler())
	t.Cleanup(httpServer.Close)
	w.url = httpServer.URL
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	w.ctx = ctx
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(w.url, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(websocket.StatusNormalClosure, "") })
	w.conn = conn
	writeProviderJSON(t, ctx, conn, protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift",
		Models:              []protocol.ModelInfo{{ID: capability.ModelID, WeightHash: capability.ModelAggregateHash}},
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	w.plan = cachePreparationPlanForTest(t, w.reg, capability)
	waitCacheCondition(t, func() bool {
		ids := w.reg.ProviderIDs()
		if len(ids) != 1 {
			return false
		}
		w.provider = w.reg.GetProvider(ids[0])
		return w.provider != nil
	})
	return w
}

func (w *cacheReceiptWire) advance(d time.Duration) { w.offset.Add(int64(d)) }

// prompt is the plan's final boundary: the anchor every lookup must prove.
func (w *cacheReceiptWire) prompt() protocol.PrefixCacheAnchor {
	return w.plan.Boundaries[len(w.plan.Boundaries)-1]
}

// boundary returns the plan's anchor at the given number of 256-token blocks.
func (w *cacheReceiptWire) boundary(blocks int) protocol.PrefixCacheAnchor {
	w.t.Helper()
	for _, anchor := range w.plan.Boundaries {
		if anchor.TokenCount == blocks*int(w.capability.BlockSize) {
			return anchor
		}
	}
	w.t.Fatalf("plan has no boundary at %d blocks", blocks)
	return protocol.PrefixCacheAnchor{}
}

// attempt prepares a coordinator attempt and returns the nonce the provider
// would have received in its inference request.
func (w *cacheReceiptWire) attempt(id string) string {
	w.t.Helper()
	pr := &registry.PendingRequest{RequestID: id, Model: w.capability.ModelID, CachePlan: w.plan}
	if err := w.reg.PrepareCacheAttempt(pr, w.provider); err != nil {
		w.t.Fatal(err)
	}
	nonce := providerInferenceWireMessage(id, "ephemeral", "ciphertext", pr).CacheReceiptNonce
	if nonce == "" {
		w.t.Fatalf("attempt %s did not prepare", id)
	}
	return nonce
}

func (w *cacheReceiptWire) lookup(id, nonce string, mutate func(*protocol.PrefixCacheLookupV2Message)) {
	w.t.Helper()
	w.seq++
	msg := protocol.PrefixCacheLookupV2Message{
		Type: protocol.TypePrefixCacheLookupV2, RequestID: id, CacheReceiptNonce: nonce,
		ModelID: w.capability.ModelID, ModelAggregateHash: w.capability.ModelAggregateHash,
		PromptContractID: w.capability.PromptContractID, CacheEpoch: w.capability.CacheEpoch,
		CacheSeq: w.seq, PromptAnchor: w.prompt(), Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if mutate != nil {
		mutate(&msg)
	}
	writeProviderJSON(w.t, w.ctx, w.conn, msg)
}

func (w *cacheReceiptWire) ready(id, nonce string, stageMs float64, anchors ...protocol.PrefixCacheAnchor) {
	w.t.Helper()
	w.seq++
	writeProviderJSON(w.t, w.ctx, w.conn, protocol.PrefixCacheReadyV2Message{
		Type: protocol.TypePrefixCacheReadyV2, RequestID: id, CacheReceiptNonce: nonce,
		ModelID: w.capability.ModelID, ModelAggregateHash: w.capability.ModelAggregateHash,
		PromptContractID: w.capability.PromptContractID, CacheEpoch: w.capability.CacheEpoch,
		CacheSeq: w.seq, Outcome: "ready", Tier: "ssd", ReadyAnchors: anchors,
		ExpectedPrefillTokensSaved: anchors[len(anchors)-1].TokenCount, StageMs: stageMs,
	})
}

func (w *cacheReceiptWire) receipts(kind, outcome, reason string) int64 {
	return w.srv.observation.Metrics().Snapshot().Counters[metricKey("exact_cache_receipt_total", []observation.MetricLabel{
		{Name: "type", Value: kind}, {Name: "outcome", Value: outcome}, {Name: "reason", Value: reason},
	})]
}

func (w *cacheReceiptWire) waitReceipt(kind, outcome, reason string, count int64) {
	w.t.Helper()
	waitCacheCondition(w.t, func() bool { return w.receipts(kind, outcome, reason) == count })
}

// waitStatus polls the public endpoint (cached for one second), so the
// projection itself is what a test asserts.
func (w *cacheReceiptWire) waitStatus(want func(ExactCacheStatus) bool) ExactCacheStatus {
	w.t.Helper()
	var status ExactCacheStatus
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		response, err := http.Get(w.url + "/v1/cache/status")
		if err != nil {
			w.t.Fatal(err)
		}
		status = ExactCacheStatus{}
		err = json.NewDecoder(response.Body).Decode(&status)
		_ = response.Body.Close()
		if err != nil {
			w.t.Fatal(err)
		}
		if want(status) {
			return status
		}
		time.Sleep(20 * time.Millisecond)
	}
	w.t.Fatalf("cache status never reached the wanted state: holders=%d lifecycle=%+v", status.Holders, status.Lifecycle)
	return status
}
