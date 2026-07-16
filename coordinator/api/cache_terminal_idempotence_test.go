package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
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
