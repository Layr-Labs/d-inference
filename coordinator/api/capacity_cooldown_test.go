package api

import (
	"bytes"
	"fmt"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// isCapacityRejectStrike must count node-scoped capacity rejections (the
// black-hole vocabulary) and NEVER count request-shape context overflows
// (deterministic for the model — they indict the request, not the provider)
// or genuine faults (owned by the 5xx breakers).
func TestIsCapacityRejectStrike(t *testing.T) {
	cases := []struct {
		name   string
		errStr string
		want   bool
	}{
		// Node-scoped capacity rejects: COUNT. These are the incident strings —
		// a pair emitting them repeatedly with zero accepts is a black hole.
		{"active token budget", "token_budget_exhausted: request exceeds active token budget", true},
		{"requires-but-available", "token_budget_exhausted: request requires 115635 tokens but only 90000 available", true},
		{"kv headroom", "token_budget_exhausted: insufficient global KV cache headroom", true},
		{"queue full", "token_budget_exhausted: request queue full", true},
		{"server busy", "server busy", true},
		{"draining", "provider draining for update", true},
		{"cold not-loaded miss", "model 'gemma-4-26b-8bit' is not loaded on this provider", true},
		// "batch token budget" is deliberately INCLUDED (misreported-budget
		// pathology rejects normal prompts with exactly this string).
		{"batch token budget", "token_budget_exhausted: request exceeds batch token budget", true},

		// Request-shape context overflows: NEVER count (identical fleet-wide;
		// striking them would cool healthy providers on oversized-prompt bursts).
		{"exceeds model context window", "token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)", false},
		{"context length exceeded", "context length exceeded", false},
		{"context window bare marker", "prompt too long for context window", false},

		// Genuine faults / non-capacity: NEVER count (the 5xx breakers own them).
		{"panic", "panic: index out of range", false},
		{"internal error", "internal error", false},
		{"bad-weights load fault", "model load failed: corrupt weights", false},
		{"opaque foundation error", "The operation couldn’t be completed. (ProviderCore.InferenceError error 1.)", false},
		{"cancel", "request cancelled", false},
		{"empty", "", false},
		// A 404-shaped "model not found" (unknown model id) is a request-shape
		// error, NOT the cold "not loaded" capacity miss — never a strike.
		{"unknown model not found", "model not found", false},
		{"unknown model in registry", "model \"nope\" not found in registry", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isCapacityRejectStrike(tc.errStr); got != tc.want {
				t.Fatalf("isCapacityRejectStrike(%q) = %v, want %v", tc.errStr, got, tc.want)
			}
		})
	}
}

func capacityTestPending(model, providerID string, n int) *registry.PendingRequest {
	return &registry.PendingRequest{
		RequestID:             fmt.Sprintf("req-cap-%s-%d", providerID, n),
		Model:                 model,
		ProviderID:            providerID,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		ChunkCh:               make(chan string, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}
}

// End-to-end incident regression: a black-hole provider (100% capacity rejects,
// zero accepts) must trip the capacity-reject cooldown through the REAL
// noteInferenceError glue, emit the routing.capacity_cooldown_tripped metric
// (tagged provider_id + model) and the distinct log line exactly once, and be
// skipped by routing so dispatch diverts to the healthy provider — while a
// busy-but-serving provider with interleaved accepts is never cooled, and a
// client-shape 4xx carrying a capacity-looking string never strikes.
func TestCapacityCooldownTripsMetricLogAndRoutingDiverts(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	var logBuf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logBuf, &slog.HandlerOptions{Level: slog.LevelWarn}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	const model = "gemma-4-26b-8bit"
	blackHole := makeRoutableProvider(t, reg, "p-blackhole", model)
	healthy := makeRoutableProvider(t, reg, "p-healthy", model)

	srv := NewServer(reg, st, ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	const rejectStr = "token_budget_exhausted: request exceeds active token budget"

	// The incident pattern: every dispatch to the black hole bounces with the
	// capacity string (classified 503) and it never serves anything.
	for i := 0; i < 8; i++ {
		srv.noteInferenceError(blackHole.ID, capacityTestPending(model, blackHole.ID, i), 503, rejectStr, "")
	}
	if !reg.CapacityCooldownActive(blackHole.ID, model) {
		t.Fatal("black-hole provider not in capacity cooldown after 8 zero-accept rejects")
	}

	// Distinct metric, tagged provider_id + model, emitted exactly once (on the
	// transition — not per straggler reject).
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	tripped := findMetrics(packets, "routing.capacity_cooldown_tripped")
	if len(tripped) != 1 {
		t.Fatalf("want exactly 1 capacity_cooldown_tripped metric, got %d: %v", len(tripped), tripped)
	}
	if !strings.Contains(tripped[0], "provider_id:"+blackHole.ID) || !strings.Contains(tripped[0], "model:"+model) {
		t.Fatalf("metric missing provider_id/model tags: %s", tripped[0])
	}
	if got := strings.Count(logBuf.String(), "capacity-reject cooldown tripped"); got != 1 {
		t.Fatalf("want exactly 1 trip log line, got %d; logs: %s", got, logBuf.String())
	}

	// Routing now diverts every dispatch to the healthy box.
	for i := 0; i < 5; i++ {
		provider, _ := reg.ReserveProviderEx(model, capacityTestPending(model, "", 100+i))
		if provider == nil {
			t.Fatal("no provider reserved — healthy box should still be routable")
		}
		if provider.ID != healthy.ID {
			t.Fatalf("reserve %d picked %s, want the healthy provider %s", i, provider.ID, healthy.ID)
		}
		reg.SetProviderIdle(provider.ID)
	}

	// Balance: the healthy box now saturates and legitimately sheds — but it
	// keeps SERVING (accepts interleaved), so it must NEVER trip.
	for round := 0; round < 5; round++ {
		for i := 0; i < 4; i++ {
			srv.noteInferenceError(healthy.ID, capacityTestPending(model, healthy.ID, round*10+i), 503, rejectStr, "")
		}
		srv.noteInferenceSuccess(capacityTestPending(model, healthy.ID, round))
	}
	if reg.CapacityCooldownActive(healthy.ID, model) {
		t.Fatal("busy-but-serving provider was cooled despite interleaved accepts")
	}

	// Client-shape 4xx carrying a capacity-looking string never strikes.
	other := makeRoutableProvider(t, reg, "p-4xx", model)
	for i := 0; i < 10; i++ {
		srv.noteInferenceError(other.ID, capacityTestPending(model, other.ID, i), 400, rejectStr, "")
	}
	if reg.CapacityCooldownActive(other.ID, model) {
		t.Fatal("client-shape 4xx with a capacity string tripped the capacity cooldown")
	}

	// Deterministic context overflows never strike either — they indict the
	// request, not the provider.
	ctxProvider := makeRoutableProvider(t, reg, "p-ctx", model)
	for i := 0; i < 10; i++ {
		srv.noteInferenceError(ctxProvider.ID, capacityTestPending(model, ctxProvider.ID, i), 503,
			"token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)", "")
	}
	if reg.CapacityCooldownActive(ctxProvider.ID, model) {
		t.Fatal("deterministic context-overflow rejections tripped the capacity cooldown")
	}
}

// The retry-amplification loop from the live incident: a sink box looks IDLE
// (near-zero active tokens), so it wins the cost score; its rejects are fast,
// so the retry path re-selects it immediately — dispatch walks straight back
// into the sink (~950 rejects/min fleet-wide) while loaded-but-healthy boxes
// get nothing. Retry re-selection funnels through ReserveProviderEx →
// providerPassesRoutingGatesLockedEx (the same gate on BOTH scan passes — the
// fail-open rescan only bypasses the node-health breaker), so after the trip
// every re-selection must divert to the healthy box within the threshold.
func TestCapacityCooldownRetryReselectionEscapesSink(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(&bytes.Buffer{}, &slog.HandlerOptions{Level: slog.LevelWarn}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	const model = "gemma-4-26b-8bit"
	sink := makeRoutableProvider(t, reg, "p-sink", model)
	healthy := makeRoutableProvider(t, reg, "p-loaded-healthy", model)
	// Incident shape: the sink looks idle and fast; the healthy box carries
	// real load and a slower decode rate, so the cost scheduler deterministically
	// prefers the sink until the cooldown gates it out.
	healthy.Mu().Lock()
	healthy.DecodeTPS = 20.0
	healthy.BackendCapacity.Slots[0].NumRunning = 3
	healthy.BackendCapacity.Slots[0].NumWaiting = 2
	healthy.Mu().Unlock()

	srv := NewServer(reg, st, ServerConfig{}, logger)

	const rejectStr = "token_budget_exhausted: request exceeds active token budget"
	sinkPicks := 0
	var servedBy string
	for attempt := 0; attempt < 12; attempt++ {
		pr := capacityTestPending(model, "", 200+attempt)
		provider, _ := reg.ReserveProviderEx(model, pr)
		if provider == nil {
			t.Fatalf("attempt %d: no provider reserved", attempt)
		}
		if provider.ID == sink.ID {
			// The sink instantly capacity-rejects; the retry loop records the
			// failure and re-selects.
			sinkPicks++
			srv.noteInferenceError(sink.ID, pr, 503, rejectStr, "")
			reg.SetProviderIdle(sink.ID)
			continue
		}
		servedBy = provider.ID
		reg.SetProviderIdle(provider.ID)
		break
	}
	if servedBy != healthy.ID {
		t.Fatalf("retry re-selection never escaped the sink (served by %q after %d sink picks)", servedBy, sinkPicks)
	}
	if sinkPicks > 5 {
		t.Fatalf("took %d sink picks to escape, want <= default threshold 5", sinkPicks)
	}
	if !reg.CapacityCooldownActive(sink.ID, model) {
		t.Fatal("sink not in capacity cooldown after the escape")
	}
	// Every subsequent selection — fresh requests AND retries — stays off the
	// sink for the cooldown's lifetime.
	for i := 0; i < 5; i++ {
		provider, _ := reg.ReserveProviderEx(model, capacityTestPending(model, "", 300+i))
		if provider == nil || provider.ID != healthy.ID {
			t.Fatalf("post-trip selection %d did not stay on the healthy box", i)
		}
		reg.SetProviderIdle(provider.ID)
	}
}
