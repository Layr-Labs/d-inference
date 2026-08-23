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

func cacheTelemetryPending(id string) *registry.PendingRequest {
	return &registry.PendingRequest{
		RequestID:          id,
		CachePlan:          testCachePlan("secret-route-" + id),
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
	}
}

func TestCacheTerminalTelemetryIsIdempotentAcrossTerminalSeams(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv := &Server{}
	srv.SetDatadog(ddClient)

	// Models a synthetic WebSocket disconnect consumed through ErrorCh: the
	// consumer's final route outcome is the only terminal seam.
	disconnected := cacheTelemetryPending("disconnect-secret")
	srv.updateInferenceRouteOutcomeForPending(disconnected, pendingRouteOutcome(disconnected, finalStatusError, "provider_disconnect_pre_commit", 502))
	// A racing provider error or late duplicate consumer update must not count it again.
	srv.emitCacheSelectionTerminal(disconnected, protocol.UsageInfo{}, false, false)
	srv.updateInferenceRouteOutcomeForPending(disconnected, pendingRouteOutcome(disconnected, finalStatusError, "provider_disconnect_pre_commit", 502))

	// A post-commit parked request has no final consumer outcome before its
	// provider completion. The validated completion must therefore still count.
	parked := cacheTelemetryPending("parked-secret")
	srv.updateInferenceRouteOutcomeForPending(parked, committedRouteOutcome(parked))
	validHit := protocol.UsageInfo{
		PromptTokens: 10, CacheOutcome: "hit", CacheTier: "ssd",
		CachedTokens: 4, PrefillTokensSaved: 3,
	}
	srv.emitCacheSelectionTerminal(parked, validHit, true, true)
	srv.emitCacheSelectionTerminal(parked, validHit, true, true)

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	terminal := findMetrics(packets, "routing.cache_selection_terminal")
	if len(terminal) != 2 {
		t.Fatalf("terminal cache metrics = %d, want one disconnect + one parked completion: %v", len(terminal), packets)
	}
	if !hasMetric(terminal, "result:unreported") || !hasMetric(terminal, "result:hit") {
		t.Fatalf("terminal outcomes missing disconnect or parked completion: %v", terminal)
	}
	joined := strings.Join(terminal, "\n")
	for _, secret := range []string{
		disconnected.RequestID,
		disconnected.CachePlan.ModelAggregateHash,
		parked.RequestID,
		parked.CachePlan.ModelAggregateHash,
	} {
		if strings.Contains(joined, secret) {
			t.Fatalf("terminal cache metric leaked identifier %q: %s", secret, joined)
		}
	}
}
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
