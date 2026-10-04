package inference_test

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestWaitFirstChunkDeferredRetryUsesCapturedCacheTerminal(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	logger := quietLogger()
	reg := registry.New(logger)
	srv := newComposedServer(reg, memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.observation.SetDatadog(ddClient)
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
		FailureCode: protocol.FailureCodeGenerationFailure,
	}
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	active := attempt.RaceAttempt{Provider: provider, Pending: pr, RequestID: pr.RequestID}
	captured := outcome.CaptureAttempt(provider, pr, pr.RequestID, pr.Attempt)
	recovery := srv.NewFirstWaitFailure(pr.Model, 0, &retry.TerminalEvidence{}, srv.NewBackendLatch(), func(*registry.Provider) {})
	var recovered attempt.RaceResult
	var held []string
	waiter := attempt.NewFirstWait(attempt.FirstWaitDependencies{
		CommitReady: func(msg protocol.InferenceErrorMessage) bool {
			return srv.NewContentCommitter().Buffered(nil, pr, &held, msg) != nil
		},
		Failure: func(msg protocol.InferenceErrorMessage, closed bool) {
			recovered = recovery.Run(r.Context(), active, pr.Attempt, msg, closed)
		},
	}, attempt.FirstWaitConfig{Pending: pr, SpeculativeAt: time.Hour, Deadline: time.Hour})
	result := waiter.RunRecorded(r.Context(), &held, captured, srv.NewRouteRecorder(), pr.Model, func(attempt.FirstWaitResult) attempt.FirstWaitTerminal {
		current := recovered.Attempt
		return attempt.FirstWaitTerminal{
			Current: outcome.CaptureAttempt(current.Provider, current.Pending, current.RequestID, pr.Attempt),
			Build:   recovered.Failure.RouteOutcome,
		}
	})
	if outcome := result.Outcome; outcome != attempt.Retry || recovered.Attempt.Pending != nil || recovered.Attempt.Provider != nil {
		t.Fatalf("waitFirstChunk outcome=%v pr=%v provider=%v, want retry with mutable state cleared", outcome, recovered.Attempt.Pending, recovered.Attempt.Provider)
	}
	// A duplicate provider terminal racing afterward must not emit again.
	srv.observation.EmitCacheSelectionTerminal(pr, protocol.UsageInfo{
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
