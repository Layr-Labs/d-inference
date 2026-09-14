package dispatch

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWaitFirstChunkDeferredRetryUsesCapturedCacheTerminal(t *testing.T) {
	srv := newTestController(t)
	reg := srv.deps.Registry()
	observer := &fixtureOutcomeObserver{fixtureObserver: fixtureObserver{store: testControllerStore(srv)}}
	srv.deps.Observer = observer
	provider := reg.Register("disconnect-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "model", ModelType: "chat"}},
	})

	pr := &registry.PendingRequest{
		RequestID: "disconnect-request", Attempt: 2, ProviderID: provider.ID, Model: "model",
		CachePlan:          testCachePlan("secret-route"),
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan registry.ProviderChunk, 1),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	pr.ErrorCh <- protocol.InferenceErrorMessage{
		Type: protocol.TypeInferenceError, RequestID: pr.RequestID,
		Error: "provider disconnected", StatusCode: 502,
	}
	d := &execution{
		s: srv, r: httptest.NewRequest("POST", "/v1/chat/completions", nil),
		model: pr.Model, provider: provider, pr: pr, requestID: pr.RequestID, attempt: pr.Attempt,
		speculativeAt: time.Hour, deadline: time.Hour,
		excludeProviders: make(map[string]struct{}),
	}
	if outcome := d.waitFirstChunk(); outcome != outcomeRetry || d.pr != nil || d.provider != nil {
		t.Fatalf("waitFirstChunk outcome=%v pr=%v provider=%v, want retry with mutable state cleared", outcome, d.pr, d.provider)
	}
	if len(observer.pending) != 1 || observer.pending[0] != pr || len(observer.cacheTerminals) != 1 || observer.cacheTerminals[0] != pr {
		t.Fatalf("retry lost captured pending terminal: pending=%v cache=%v", observer.pending, observer.cacheTerminals)
	}
}

func TestDispatchRoutingOutcomePreservesMismatchedPendingFallback(t *testing.T) {
	pr := cacheTelemetryPending("other-request")
	d := &execution{
		s: newTestController(t), model: "model", pr: pr,
		requestID: "current-request", attempt: pr.Attempt + 1,
	}
	observer := &fixtureOutcomeObserver{fixtureObserver: fixtureObserver{store: testControllerStore(d.s)}}
	d.s.deps.Observer = observer
	d.updateRoutingOutcome(attempt.RouteOutcome(attempt.FinalStatusError, "provider_error", 502))
	if !pr.MarkCacheTerminalTelemetryEmitted() {
		t.Fatal("mismatched pending request incorrectly consumed cache terminal hook")
	}
	if len(observer.pending) != 0 || len(observer.cacheTerminals) != 0 || len(observer.routes) != 1 || observer.routes[0].id != "current-request" || observer.routes[0].attempt != pr.Attempt+1 {
		t.Fatalf("mismatched pending crossed the publication boundary: %+v", observer)
	}
}
