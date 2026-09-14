package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCapturedDispatchRetryClosesCacheTerminalOnce(t *testing.T) {
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
		ChunkCh:                make(chan registry.ProviderChunk, 1),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	pr.ErrorCh <- protocol.InferenceErrorMessage{
		Type: protocol.TypeInferenceError, RequestID: pr.RequestID,
		Error: "provider disconnected", StatusCode: 502,
	}
	// The dispatch owner separately proves the retry passes this exact pending
	// identity after clearing mutable state. Exercise the real API publication.
	dispatchObserver{server: srv}.PendingOutcome(pr, attempt.PendingRouteOutcome(pr, attempt.FinalStatusError, "provider_disconnect_pre_commit", 502))
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
