package api

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestWaitFirstChunkDeferredRetryUsesCapturedCacheTerminal(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetDatadog(ddClient)
	provider := reg.Register("disconnect-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "model", ModelType: "chat"}},
	})

	pr := &registry.PendingRequest{
		RequestID: "disconnect-request", Attempt: 2, ProviderID: provider.ID, Model: "model",
		CachePlan:          testCachePlan("secret-route"),
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, 1),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	pr.ErrorCh <- protocol.InferenceErrorMessage{
		Type: protocol.TypeInferenceError, RequestID: pr.RequestID,
		Error: "provider disconnected", StatusCode: 502,
	}
	d := &dispatchState{
		s: srv, r: httptest.NewRequest("POST", "/v1/chat/completions", nil),
		model: pr.Model, provider: provider, pr: pr, requestID: pr.RequestID, attempt: pr.Attempt,
		speculativeAt: time.Hour, deadline: time.Hour,
		excludeProviders: make(map[string]struct{}),
	}
	if outcome := d.waitFirstChunk(); outcome != outcomeRetry || d.pr != nil || d.provider != nil {
		t.Fatalf("waitFirstChunk outcome=%v pr=%v provider=%v, want retry with mutable state cleared", outcome, d.pr, d.provider)
	}
	// A duplicate provider terminal racing afterward must not emit again.
	srv.emitCacheSelectionTerminal(pr, protocol.UsageInfo{
		PromptTokens: 10, CacheOutcome: "hit", CacheTier: "memory",
		CachedTokens: 4, PrefillTokensSaved: 3,
	}, true, true)

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	terminal := findMetrics(packets, "routing.cache_selection_terminal")
	if len(terminal) != 1 || !hasMetric(terminal, "result:unreported") {
		t.Fatalf("synthetic disconnect terminal metrics = %v, want one unreported", terminal)
	}
	if strings.Contains(strings.Join(terminal, "\n"), pr.RequestID) ||
		strings.Contains(strings.Join(terminal, "\n"), pr.CachePlan.ModelAggregateHash) {
		t.Fatalf("synthetic disconnect metric leaked identifiers: %v", terminal)
	}
}

func TestDispatchRoutingOutcomePreservesMismatchedPendingFallback(t *testing.T) {
	pr := cacheTelemetryPending("other-request")
	d := &dispatchState{
		s: &Server{}, model: "model", pr: pr,
		requestID: "current-request", attempt: pr.Attempt + 1,
	}
	d.updateRoutingOutcome(routeOutcome(finalStatusError, "provider_error", 502))
	if !pr.MarkCacheTerminalTelemetryEmitted() {
		t.Fatal("mismatched pending request incorrectly consumed cache terminal hook")
	}
}
