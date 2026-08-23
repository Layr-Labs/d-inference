package api

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

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
		srv.noteInferenceError(blackHole.ID, capacityTestPending(model, blackHole.ID, i), 503, rejectStr, "", "")
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
			srv.noteInferenceError(healthy.ID, capacityTestPending(model, healthy.ID, round*10+i), 503, rejectStr, "", "")
		}
		srv.noteInferenceSuccess(capacityTestPending(model, healthy.ID, round))
	}
	if reg.CapacityCooldownActive(healthy.ID, model) {
		t.Fatal("busy-but-serving provider was cooled despite interleaved accepts")
	}

	// Client-shape 4xx carrying a capacity-looking string never strikes.
	other := makeRoutableProvider(t, reg, "p-4xx", model)
	for i := 0; i < 10; i++ {
		srv.noteInferenceError(other.ID, capacityTestPending(model, other.ID, i), 400, rejectStr, "", "")
	}
	if reg.CapacityCooldownActive(other.ID, model) {
		t.Fatal("client-shape 4xx with a capacity string tripped the capacity cooldown")
	}

	// Deterministic context overflows never strike either — they indict the
	// request, not the provider.
	ctxProvider := makeRoutableProvider(t, reg, "p-ctx", model)
	for i := 0; i < 10; i++ {
		srv.noteInferenceError(ctxProvider.ID, capacityTestPending(model, ctxProvider.ID, i), 503,
			"token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)", "", "")
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
			srv.noteInferenceError(sink.ID, pr, 503, rejectStr, "", "")
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
// A box that cold-404s ("model not loaded") FOREVER with zero accepts is a
// black hole and must trip; a box that 404s while lazily loading and then
// SERVES (the normal lifecycle) must never trip — the accept is the safety.
func TestCapacityCooldown404NotLoadedStrikes(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const model = "gemma-4-26b-8bit"
	const notLoaded = "model 'gemma-4-26b-8bit' is not loaded on this provider"

	// Normal lazy-load lifecycle: a few cold 404s, then the load completes and
	// the box serves. The accept resets the streak every round — never trips.
	lazy := makeRoutableProvider(t, reg, "p-lazy-load", model)
	for round := 0; round < 4; round++ {
		for i := 0; i < 3; i++ {
			srv.noteInferenceError(lazy.ID, capacityTestPending(model, lazy.ID, round*10+i), http.StatusNotFound, notLoaded, "", "")
		}
		srv.noteInferenceSuccess(capacityTestPending(model, lazy.ID, round))
	}
	if reg.CapacityCooldownActive(lazy.ID, model) {
		t.Fatal("404-then-load-then-serve lifecycle tripped the capacity cooldown")
	}

	// Black hole flavor: 404s forever, zero accepts — trips at the threshold.
	stuck := makeRoutableProvider(t, reg, "p-never-loads", model)
	for i := 0; i < 5; i++ {
		srv.noteInferenceError(stuck.ID, capacityTestPending(model, stuck.ID, i), http.StatusNotFound, notLoaded, "", "")
	}
	if !reg.CapacityCooldownActive(stuck.ID, model) {
		t.Fatal("a box that 404s 'not loaded' forever with zero accepts did not trip")
	}

	// A 404 whose message is NOT the capacity vocabulary (unknown model id — a
	// request-shape error) never strikes, no matter how many arrive.
	notFound := makeRoutableProvider(t, reg, "p-model-not-found", model)
	for i := 0; i < 10; i++ {
		srv.noteInferenceError(notFound.ID, capacityTestPending(model, notFound.ID, i), http.StatusNotFound, "model not found", "", "")
	}
	if reg.CapacityCooldownActive(notFound.ID, model) {
		t.Fatal("request-shape 404 'model not found' tripped the capacity cooldown")
	}
}

// Cold "model not loaded" misses must NOT derate the gray-box capacity-503
// RATE window, even over the sample floor and with interleaved accepts (the
// normal lazy-load lifecycle) — the rate window has no accept-reset, so
// counting a healthy box's reloads would penalize it. A genuine token-budget
// 503 on the same path DOES derate. Codex review of #523.
func TestCapacityRateExcludesColdModelMiss(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const model = "gemma-4-26b-8bit"
	const notLoaded = "model 'gemma-4-26b-8bit' is not loaded on this provider"
	const genuine = "token_budget_exhausted: request exceeds active token budget"
	const sampleFloor = 8 // registry.capacityRateMinSample (unexported)

	// Cold-miss box: cold "not loaded" 404s over the sample floor, each followed
	// by a served completion (the normal lazy-load lifecycle). The rate window
	// must stay empty.
	cold := makeRoutableProvider(t, reg, "p-cold-miss", model)
	for i := 0; i < sampleFloor; i++ {
		srv.noteInferenceError(cold.ID, capacityTestPending(model, cold.ID, i), http.StatusNotFound, notLoaded, "", "")
		srv.noteInferenceSuccess(capacityTestPending(model, cold.ID, i))
	}
	if rate, samples := reg.CapacityRejectRate(cold.ID, model); samples != 0 || rate != 0 {
		t.Fatalf("cold 'not loaded' misses derated the capacity-reject rate: rate=%.2f samples=%d, want 0/0", rate, samples)
	}

	// Gray-box: genuine token-budget 503s with interleaved accepts DO accumulate
	// the rate — the mechanism the penalty exists for.
	gray := makeRoutableProvider(t, reg, "p-graybox", model)
	for i := 0; i < sampleFloor; i++ {
		srv.noteInferenceError(gray.ID, capacityTestPending(model, gray.ID, i), http.StatusServiceUnavailable, genuine, "", "")
		srv.noteInferenceSuccess(capacityTestPending(model, gray.ID, i))
	}
	if rate, samples := reg.CapacityRejectRate(gray.ID, model); samples == 0 || rate <= 0 {
		t.Fatalf("genuine token-budget 503s must derate the rate: rate=%.2f samples=%d", rate, samples)
	}
}

// A "batch token budget" reject that classifyRejection proves REQUEST-
// deterministic (the rejecting provider's reported budget is not below the
// model context, so the prompt exceeded the fleet-wide context) indicts the
// request, not the provider: it must arm NEITHER the one-shot budget clamp NOR
// the no-reset capacity-503 rate window — a single oversized prompt would
// otherwise gate/derate a healthy pair. It still counts a cooldown strike (a
// budget-misreporting box rejects normal prompts with this exact string, and
// the cooldown's accept-reset makes strikes safe for healthy pairs). When the
// reported budget IS below the context (node memory pressure — provider-
// specific), the same string feeds the full gray-box state. Codex review of
// #523, round 3.
func TestCapacityRejectDeterministicBatchBudgetArmsNoGrayBoxState(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const model = "batch-budget-model"
	const batchBudget = "token_budget_exhausted: request exceeds batch token budget"
	registerModelContext(t, st, model, 131072)

	// Deterministic: reported budget (5M) >= model context (131072) — the
	// binding term was the context, identical fleet-wide.
	det := makeRoutableProvider(t, reg, "p-oversized-prompt", model)
	setProviderModelBudget(t, reg, det.ID, model, 5_000_000)
	srv.noteInferenceError(det.ID, capacityTestPending(model, det.ID, 0), http.StatusServiceUnavailable, batchBudget, "", "")
	if reg.BudgetClampActive(det.ID, model) {
		t.Fatal("a request-deterministic batch-budget reject must not arm the budget clamp")
	}
	if _, samples := reg.CapacityRejectRate(det.ID, model); samples != 0 {
		t.Fatalf("a request-deterministic batch-budget reject must not derate: samples=%d, want 0", samples)
	}
	// ...but repeated ones with zero interleaved accepts still trip the
	// black-hole cooldown (the budget-misreporting signature).
	for i := 1; i < 5; i++ {
		srv.noteInferenceError(det.ID, capacityTestPending(model, det.ID, i), http.StatusServiceUnavailable, batchBudget, "", "")
	}
	if !reg.CapacityCooldownActive(det.ID, model) {
		t.Fatal("repeated deterministic batch-budget rejects with zero accepts must still trip the cooldown")
	}

	// Node-pressured: reported budget (90k) < model context (131072) — the
	// binding term may have been THIS node's shrunk KV budget, a genuine
	// provider-specific capacity signal: full gray-box state.
	pressured := makeRoutableProvider(t, reg, "p-pressured", model)
	setProviderModelBudget(t, reg, pressured.ID, model, 90_000)
	srv.noteInferenceError(pressured.ID, capacityTestPending(model, pressured.ID, 0), http.StatusServiceUnavailable, batchBudget, "", "")
	if !reg.BudgetClampActive(pressured.ID, model) {
		t.Fatal("a node-pressured batch-budget reject (budget < context) must arm the budget clamp")
	}
	if _, samples := reg.CapacityRejectRate(pressured.ID, model); samples != 1 {
		t.Fatalf("a node-pressured batch-budget reject must derate: samples=%d, want 1", samples)
	}
}

// The gray-box request-shape classification must TRUST a provider's
// structured ErrorReason over the stale heartbeat-budget heuristic, exactly
// like the dispatch failover does (Codex review of #523, round 4): a newer
// provider that says request_exceeds_node_budget with a "batch token budget"
// string is reporting a node-specific capacity failure — even when its stale
// reported budget still reads >= the model context — so the reject must feed
// the full gray-box state, not be misrouted to the strike-only request-shape
// path. Conversely an explicit request_exceeds_context reason is request-
// deterministic regardless of string or budget.
func TestGrayBoxClassificationTrustsStructuredReason(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const model = "reasoned-batch-budget-model"
	const batchBudget = "token_budget_exhausted: request exceeds batch token budget"
	registerModelContext(t, st, model, 131072)

	// Structured node-specific reason + stale budget >= context: the reason
	// wins — full gray-box state (clamp + rate), not the request-shape path.
	nodeBudget := makeRoutableProvider(t, reg, "p-reasoned-node", model)
	setProviderModelBudget(t, reg, nodeBudget.ID, model, 5_000_000)
	srv.noteInferenceError(nodeBudget.ID, capacityTestPending(model, nodeBudget.ID, 0),
		http.StatusServiceUnavailable, batchBudget, "request_exceeds_node_budget", "")
	if !reg.BudgetClampActive(nodeBudget.ID, model) {
		t.Fatal("a structured request_exceeds_node_budget reason must feed the clamp despite the stale >=context budget snapshot")
	}
	if _, samples := reg.CapacityRejectRate(nodeBudget.ID, model); samples != 1 {
		t.Fatalf("a structured node-budget reject must derate: samples=%d, want 1", samples)
	}

	// No reason (legacy provider): the budget heuristic still applies —
	// budget >= context reads request-deterministic, strike-only.
	legacy := makeRoutableProvider(t, reg, "p-reasonless", model)
	setProviderModelBudget(t, reg, legacy.ID, model, 5_000_000)
	srv.noteInferenceError(legacy.ID, capacityTestPending(model, legacy.ID, 0),
		http.StatusServiceUnavailable, batchBudget, "", "")
	if reg.BudgetClampActive(legacy.ID, model) {
		t.Fatal("reasonless deterministic batch-budget reject must stay strike-only (heuristic unchanged)")
	}

	// Explicit request_exceeds_context reason on a NON-batch capacity string
	// from a pressured-looking provider: request-deterministic — no gray-box
	// state, even though the budget heuristic alone would have said transient.
	ctxReason := makeRoutableProvider(t, reg, "p-reasoned-ctx", model)
	setProviderModelBudget(t, reg, ctxReason.ID, model, 90_000)
	srv.noteInferenceError(ctxReason.ID, capacityTestPending(model, ctxReason.ID, 0),
		http.StatusServiceUnavailable,
		"token_budget_exhausted: request requires 200000 tokens but only 90000 available",
		"request_exceeds_context", "")
	if reg.BudgetClampActive(ctxReason.ID, model) {
		t.Fatal("an explicit request_exceeds_context reason must not arm the clamp")
	}
	if _, samples := reg.CapacityRejectRate(ctxReason.ID, model); samples != 0 {
		t.Fatalf("an explicit request_exceeds_context reason must not derate: samples=%d, want 0", samples)
	}
}

// After-commit client-gone regression: a stream that commits before the pair's
// first windowed reject records its accept immediately. If the consumer then
// disconnects and the provider completes into the parked settlement path,
// handleComplete must observe the commit-time stamp and avoid counting it again.
func TestCapacityRateParkedCompletionCountsAtHandleComplete(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const model = "gemma-4-26b-8bit"
	p := makeRoutableProvider(t, reg, "p-parked", model)

	pr := capacityTestPending(model, p.ID, 1)
	pr.ConsumerKey = "test-key"

	// Commit first content while the pair is healthy (no reject in-window yet),
	// mirroring commitFirstContent and its request-local exactly-once stamp.
	if !reg.RecordCapacityAccept(pr.ProviderID, model) {
		t.Fatal("commit-time accept must be retained before the first reject")
	}
	pr.MarkRateOutcomeCounted()

	// The pair goes gray while the (now client-gone) stream is still serving.
	reg.RecordCapacityReject(pr.ProviderID, model)
	if _, samples := reg.CapacityRejectRate(pr.ProviderID, model); samples != 2 {
		t.Fatalf("setup: samples=%d after one accept and one reject, want 2", samples)
	}

	// Consumer disconnected mid-stream: the request is parked (no reader), then
	// the provider completes. handleComplete claims the parked record
	// (consumerGone=true) and must not re-offer the already recorded accept.
	srv.holdForSettlement(pr)
	srv.handleComplete(p.ID, p, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200},
	})

	rate, samples := reg.CapacityRejectRate(pr.ProviderID, model)
	if samples != 2 {
		t.Fatalf("samples=%d after parked completion, want 2 — completion double-counted the commit", samples)
	}
	if rate != 0.5 {
		t.Fatalf("rate=%.2f, want 0.5 (1 reject / 2 outcomes)", rate)
	}
}

// The generic-path accept regression (P2 #1): a busy box serving a LONG
// /v1/completions stream sheds 5 capacity rejects inside the window. The
// stream's first content is an ACCEPT interleaved with the rejects, so the
// pair must NEVER trip — before the fix the generic path recorded accepts
// only at clean completion, so the in-flight stream could not vouch for the
// box and the shed storm read as the zero-accepts black-hole signature.
func TestCapacityCooldownGenericStreamAcceptPreventsFalseTrip(t *testing.T) {
	// Crisp failure mode if the pair DOES trip: fast-shed 429 instead of a
	// 120s queue hang. Both flags are read live per request.
	t.Setenv("EIGENINFERENCE_QUEUE_BEFORE_SHED", "false")
	t.Setenv("EIGENINFERENCE_COLD_DISPATCH", "false")

	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "generic-accept-model"
	const holdMarker = "GENERIC-HOLD"
	const endMarker = "GENERIC-END"
	release := make(chan struct{})
	var chatServe atomic.Bool

	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if bytes.Contains(body, []byte("long generic stream")) {
			// The long generic stream: first content immediately (the ACCEPT),
			// then hold the stream open while the shed storm runs. In a
			// goroutine — the script runs on the provider read loop, which must
			// stay free to reject the concurrent chat dispatches.
			go func() {
				fp.sendContentChunk(ctx, req, model, holdMarker+" ")
				select {
				case <-release:
				case <-ctx.Done():
					return
				}
				fp.sendContentChunk(ctx, req, model, endMarker)
				fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 2})
			}()
			return
		}
		if chatServe.Load() {
			fp.serveFull(ctx, req, model, markerFor(fp.name))
			return
		}
		fp.sendInferenceError(ctx, req, "token_budget_exhausted: request exceeds active token budget", http.StatusServiceUnavailable)
	}
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-busy", Version: "0.7.2", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	rejectOnce := func(n int) {
		t.Helper()
		status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
		if err != nil {
			t.Fatalf("shed request %d: %v", n, err)
		}
		if status == http.StatusOK {
			t.Fatalf("shed request %d unexpectedly served; body=%s", n, body)
		}
	}

	// Rejects 1-2: the box is saturated and sheds.
	rejectOnce(1)
	rejectOnce(2)

	// Start the LONG generic stream and read up to its first content — the
	// coordinator records the ACCEPT at the commit, before relaying the chunk,
	// so seeing the marker guarantees the accept has landed.
	genBody := fmt.Sprintf(`{"model":%q,"prompt":"long generic stream","stream":true,"max_tokens":64}`, model)
	genReq, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/completions", strings.NewReader(genBody))
	if err != nil {
		t.Fatalf("generic request: %v", err)
	}
	genReq.Header.Set("Authorization", "Bearer test-key")
	genReq.Header.Set("Content-Type", "application/json")
	genResp, err := http.DefaultClient.Do(genReq)
	if err != nil {
		t.Fatalf("generic request: %v", err)
	}
	defer genResp.Body.Close()
	if genResp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(genResp.Body)
		t.Fatalf("generic stream status = %d, want 200; body=%s", genResp.StatusCode, b)
	}
	genReader := bufio.NewReader(genResp.Body)
	for {
		line, err := genReader.ReadString('\n')
		if err != nil {
			t.Fatalf("generic stream ended before first content: %v", err)
		}
		if strings.Contains(line, holdMarker) {
			break
		}
	}

	// Rejects 3-5 while the stream is STILL in flight: 5 total rejects inside
	// the window — but the stream's first-content accept interleaved, so the
	// post-accept streak is only 3 and the pair must not be cooled.
	rejectOnce(3)
	rejectOnce(4)
	rejectOnce(5)

	// The box frees up: the next chat request must route to it and serve. A
	// falsely-tripped cooldown would fast-shed this with a 429 instead.
	chatServe.Store(true)
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("post-storm request: %v", err)
	}
	if status != http.StatusOK || !strings.Contains(body, markerFor("provider-busy")) {
		t.Fatalf("busy-but-serving box was cooled by sheds during its long generic stream: status=%d body=%s", status, body)
	}

	// Sanity: every request above actually reached the provider (strikes and
	// the accept were real, not admission-filtered away).
	if got := fp.dispatchCount(); got != 7 {
		t.Errorf("provider dispatches = %d, want 7 (2 rejects + generic + 3 rejects + serve)", got)
	}

	// Let the held stream finish cleanly.
	close(release)
	rest, _ := io.ReadAll(genResp.Body)
	if !strings.Contains(string(rest), endMarker) {
		t.Errorf("generic stream missing tail content after release; got: %s", string(rest))
	}
}

// The all-cooled surfacing regression (P2 #4): when EVERY provider for a model
// is capacity-cooled, the preflight must classify them as TRANSIENT capacity
// rejections — a 429 with Retry-After and ZERO provider dispatches — not as
// structural absence (a "no providers" 503). Replays the incident shape end to
// end: black-hole boxes trip, then the next request is shed cleanly upstream.
func TestCapacityCooldownAllCooledSurfaces429NotNoProvider(t *testing.T) {
	// Threshold 2 so both pairs trip within two requests (read at registry
	// construction inside setupFailoverServer); fast-shed + no cold-dispatch so
	// the all-cooled preflight verdict surfaces as an immediate 429 rather
	// than a queue spill (both read live per request).
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "2")
	t.Setenv("EIGENINFERENCE_QUEUE_BEFORE_SHED", "false")
	t.Setenv("EIGENINFERENCE_COLD_DISPATCH", "false")

	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "all-cooled-model"
	script := rejectScript("token_budget_exhausted: request exceeds active token budget", http.StatusServiceUnavailable)
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.7.2", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.7.2", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	// Drive the incident loop until the preflight sheds WITHOUT touching a
	// provider: that is the all-cooled verdict. Each earlier warmup request
	// burns dispatches on the rejecting pairs and accumulates their strikes.
	var shedResp *http.Response
	var shedBody string
	for i := 0; i < 8; i++ {
		before := pA.dispatchCount() + pB.dispatchCount()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
			strings.NewReader(buildChatBody(t, model, false, nil)))
		if err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			t.Fatalf("request %d unexpectedly served; body=%s", i, b)
		}
		if after := pA.dispatchCount() + pB.dispatchCount(); after == before {
			// No provider was dispatched: the preflight itself shed this one.
			shedResp, shedBody = resp, string(b)
			break
		}
	}
	if shedResp == nil {
		t.Fatal("preflight never shed without dispatching — cooled pairs are not being counted as capacity rejections")
	}

	// The all-cooled verdict must read as TRANSIENT capacity: 429 +
	// Retry-After + the rate-limit error shape — never a structural
	// no-provider / model-unavailable 503.
	if shedResp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("all-cooled preflight status = %d, want 429; body=%s", shedResp.StatusCode, shedBody)
	}
	if shedResp.Header.Get("Retry-After") == "" {
		t.Errorf("all-cooled 429 missing Retry-After header")
	}
	if !strings.Contains(shedBody, "rate_limit_exceeded") || !strings.Contains(shedBody, "at capacity") {
		t.Errorf("all-cooled shed body is not the capacity shape; body=%s", shedBody)
	}
	if strings.Contains(shedBody, "no_provider") || strings.Contains(shedBody, "model_unavailable") {
		t.Errorf("all-cooled shed misclassified as structural absence; body=%s", shedBody)
	}
}
