package api

// Integration tests asserting the routing-observability metrics defined in
// internal/metrics actually fire from the live HTTP / WebSocket paths.
//
// Unit-level coverage of ReserveProviderEx and the queue dispatch lives in
// internal/registry/scheduler_test.go. These tests catch the wiring layer
// — that consumer.go and provider.go call Inc/Observe with the right
// labels at the right places.
//
// Counters are package-level globals (promauto), so each test snapshots
// the relevant series before doing work and asserts a delta after.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/metrics"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"nhooyr.io/websocket"
)

// randSuffix returns a short random suffix so metric label series can
// be uniquely scoped per test run, avoiding cross-test counter pollution.
func randSuffix() string { return fmt.Sprintf("%08x", rand.Uint32()) }

// A successful provider WebSocket connect + initial challenge round-trip
// must increment AttestationChallenges{outcome="sent"} and {outcome="passed"}.
// The challenge is fired immediately on registration, not on a ticker, so
// no sleep loop is needed.
func TestMetrics_AttestationChallengesIncrementOnHandshake(t *testing.T) {
	_, _, _, ts := setupTestServer(t)
	defer ts.Close()

	sentBefore := testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("sent"))
	passedBefore := testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("passed"))

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "metrics-attest-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Read the challenge, respond with a valid response. Coordinator
	// processes the response synchronously inside the verify path, so by
	// the time the next read returns (or times out) the metrics have moved.
	readCtx, readCancel := context.WithTimeout(ctx, 3*time.Second)
	defer readCancel()
	_, data, err := conn.Read(readCtx)
	if err != nil {
		t.Fatalf("read challenge: %v", err)
	}
	var env struct {
		Type string `json:"type"`
	}
	json.Unmarshal(data, &env)
	if env.Type != protocol.TypeAttestationChallenge {
		t.Fatalf("first message type = %q, want %q", env.Type, protocol.TypeAttestationChallenge)
	}
	resp := makeValidChallengeResponse(data, pubKey)
	if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
		t.Fatalf("write response: %v", err)
	}

	// Coordinator processes the response on its read goroutine. Poll
	// briefly for the passed counter to move so we don't race the
	// verifyChallengeResponse goroutine.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("passed")) > passedBefore {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	sentDelta := testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("sent")) - sentBefore
	passedDelta := testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("passed")) - passedBefore

	if sentDelta < 1 {
		t.Errorf("AttestationChallenges{sent} delta = %f, want >= 1", sentDelta)
	}
	if passedDelta < 1 {
		t.Errorf("AttestationChallenges{passed} delta = %f, want >= 1", passedDelta)
	}
}

// A challenge response with the wrong public key triggers
// handleChallengeFailure, which must increment {outcome="failed"}.
func TestMetrics_AttestationChallengesIncrementOnFailure(t *testing.T) {
	_, _, _, ts := setupTestServer(t)
	defer ts.Close()

	failedBefore := testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("failed"))

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "metrics-attest-fail-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	readCtx, readCancel := context.WithTimeout(ctx, 3*time.Second)
	defer readCancel()
	_, data, err := conn.Read(readCtx)
	if err != nil {
		t.Fatalf("read challenge: %v", err)
	}
	// Wrong public key — verifyChallengeResponse calls handleChallengeFailure.
	if err := conn.Write(ctx, websocket.MessageText, makeInvalidChallengeResponse(data)); err != nil {
		t.Fatalf("write invalid response: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("failed")) > failedBefore {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	if delta := testutil.ToFloat64(metrics.AttestationChallenges.WithLabelValues("failed")) - failedBefore; delta < 1 {
		t.Errorf("AttestationChallenges{failed} delta = %f, want >= 1", delta)
	}
}

// A POST /v1/chat/completions for a model with no registered provider
// goes onto the per-model wait queue (Enqueue succeeds with default
// queue size 10). The {outcome="queued"} counter must increment when
// the request enters the queue, not when the queue eventually times
// out. We cancel the client context after a short wait to avoid the
// full 120s queue timeout.
func TestMetrics_RoutingDecisionsIncrementsQueued(t *testing.T) {
	srv, _, _, ts := setupTestServer(t)
	defer ts.Close()
	srv.SetAdminKey("test-key")

	model := "metrics-queued-model-" + randSuffix()
	queuedBefore := testutil.ToFloat64(metrics.RoutingDecisions.WithLabelValues(model, "queued"))

	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"messages":   []map[string]string{{"role": "user", "content": "ping"}},
		"max_tokens": 16,
	})
	clientCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(clientCtx, "POST", ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")

	// We expect the client to either get a 503 (if the queue times out
	// — only on slow CI) or have its context cancelled. Either path is
	// fine; what matters is that the queued counter incremented when
	// the request reached the queue.
	resp, err := http.DefaultClient.Do(req)
	if err == nil {
		resp.Body.Close()
	}

	if delta := testutil.ToFloat64(metrics.RoutingDecisions.WithLabelValues(model, "queued")) - queuedBefore; delta < 1 {
		t.Errorf("RoutingDecisions{queued} delta = %f, want >= 1", delta)
	}
}

// When the per-model queue is at capacity, Enqueue returns ErrQueueFull
// and the handler must increment {outcome="over_capacity"} (not
// {queued}). Forcing this requires a queue of size zero.
func TestMetrics_RoutingDecisionsIncrementsOverCapacity(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	srv.SetAdminKey("test-key")

	// Replace the queue with one that rejects every Enqueue.
	reg.SetQueue(registry.NewRequestQueue(0, 1*time.Second))

	model := "metrics-over-cap-model-" + randSuffix()
	overCapBefore := testutil.ToFloat64(metrics.RoutingDecisions.WithLabelValues(model, "over_capacity"))

	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"messages":   []map[string]string{{"role": "user", "content": "ping"}},
		"max_tokens": 16,
	})
	req, _ := http.NewRequest("POST", ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/chat/completions: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", resp.StatusCode)
	}

	if delta := testutil.ToFloat64(metrics.RoutingDecisions.WithLabelValues(model, "over_capacity")) - overCapBefore; delta < 1 {
		t.Errorf("RoutingDecisions{over_capacity} delta = %f, want >= 1", delta)
	}
}

// /metrics must publish the new instrument names so a Prometheus scrape
// can discover them. Names are stable user-facing identifiers; this test
// fails fast if someone renames a metric.
func TestMetrics_RoutingMetricsAppearInExposition(t *testing.T) {
	_, _, _, ts := setupTestServer(t)
	defer ts.Close()

	// Pre-touch each series so it appears in the exposition (counters
	// without observed labels are absent from the output).
	metrics.RoutingDecisions.WithLabelValues("expo-touch", "selected").Add(0)
	metrics.ProviderSelected.WithLabelValues("expo-provider", "expo-touch").Add(0)
	metrics.RoutingCostMs.WithLabelValues("expo-touch").Observe(0)
	metrics.AttestationChallenges.WithLabelValues("sent").Add(0)

	resp, err := http.Get(ts.URL + "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics: %v", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read /metrics body: %v", err)
	}
	body := string(raw)

	wantNames := []string{
		"eigeninference_routing_decisions_total",
		"eigeninference_provider_selected_total",
		"eigeninference_routing_cost_milliseconds",
		"eigeninference_attestation_challenges_total",
	}
	for _, name := range wantNames {
		if !strings.Contains(body, name) {
			t.Errorf("/metrics missing %q", name)
		}
	}
}
