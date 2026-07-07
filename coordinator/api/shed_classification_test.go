package api

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// Tests for the shed re-key: the uptime-neutral 429-vs-503 classification on
// the no-eligible-provider preflight branch keys ONLY on provider existence
// (HasProviderForModel), never on IsDedicatedModel — so clearing
// EIGENINFERENCE_DEDICATED_MODELS is a pure routing-policy flip that cannot
// change shed classification.

// setupShedClassification boots a coordinator with a live DogStatsD UDP
// collector so the routing.decisions tags can be asserted alongside the HTTP
// classification. drainMetrics flushes the buffered statsd client and returns
// the collected packets.
func setupShedClassification(t *testing.T) (ts *httptest.Server, reg *registry.Registry, drainMetrics func() []string) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg = registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour
	collector := newUDPCollector(t)
	t.Cleanup(collector.Close)
	dd := newTestDD(t, collector)
	t.Cleanup(func() { dd.Close() })
	srv.SetDatadog(dd)
	ts = httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, reg, func() []string {
		_ = dd.Statsd.Flush()
		return collector.drain()
	}
}

// TestShedReKey429WhenProviderExistsWithoutDedicated is the re-key regression
// (fails with the old IsDedicatedModel trigger): DEDICATED is UNSET, a
// NON-dedicated model's only provider is structurally ineligible right now
// (thermal-critical — zero candidates, zero capacity rejections), but the
// provider EXISTS, so the shed must be an uptime-neutral 429 + Retry-After.
// Before the re-key this exact state returned a 503. A model with no provider
// at all keeps the 503. The routing.decisions emission keeps the historical
// outcome tag and adds reason:provider_exists for the re-keyed trigger.
func TestShedReKey429WhenProviderExistsWithoutDedicated(t *testing.T) {
	ts, reg, drainMetrics := setupShedClassification(t)
	// Pin the preflight shed path: no queue spill via cold dispatch.
	t.Setenv(envColdDispatch, "false")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	model := "shed-rekey-test"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: model, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	// Thermal-critical: passes the structural routing gates (still online,
	// trusted, serving the catalog model — HasProviderForModel is true) but is
	// excluded from candidacy without counting as a capacity rejection, which is
	// exactly the zero-candidates/zero-rejections branch under re-key.
	p.Mu().Lock()
	p.SystemMetrics.ThermalState = "critical"
	p.Mu().Unlock()

	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, model)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (provider exists => uptime-neutral shed); body = %s", status, body)
	}
	if !strings.Contains(body, "rate_limit_exceeded") {
		t.Fatalf("body = %s, want rate_limit_exceeded", body)
	}
	if retryAfter == "" {
		t.Fatal("429 missing Retry-After header")
	}

	// The emission keeps the historical outcome tag (dashboards key on it) and
	// tags the re-keyed trigger reason.
	decisions := findMetrics(drainMetrics(), "outcome:dedicated_capacity_429")
	if len(decisions) == 0 {
		t.Fatal("no routing.decisions packet with outcome:dedicated_capacity_429")
	}
	if !strings.Contains(decisions[0], "reason:provider_exists") {
		t.Fatalf("decision packet = %s, want reason:provider_exists tag", decisions[0])
	}

	// A model truly absent from the fleet is still a 503 — the re-key must not
	// turn structural absence into an endless-retry 429.
	statusC, bodyC, _, err := chatRequestWithHeaders(ctx, ts.URL, "totally-absent-model")
	if err != nil {
		t.Fatalf("control request: %v", err)
	}
	if statusC != http.StatusServiceUnavailable {
		t.Fatalf("absent-model status = %d, want 503; body = %s", statusC, bodyC)
	}
	if !strings.Contains(bodyC, "model_unavailable") {
		t.Fatalf("absent-model body = %s, want model_unavailable", bodyC)
	}
}

// TestShedReKeyDedicatedTaggedButNotClassifying verifies the DEDICATED-set
// behavior is preserved under re-key: a dedicated-family model whose only
// provider is a mixed (non-dedicated) box still sheds 429 + Retry-After
// (HasProviderForModel is true — same outcome as the old dedicated trigger),
// and the emission tags reason:dedicated so the old and re-keyed triggers can
// be told apart on the dashboard.
func TestShedReKeyDedicatedTaggedButNotClassifying(t *testing.T) {
	ts, reg, drainMetrics := setupShedClassification(t)
	reg.SetDedicatedModels([]string{"gemma-4"})
	t.Setenv(envColdDispatch, "false")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	gemma := "gemma-4-26b-test"
	qwen := "qwen-3-test"
	// One MIXED provider (gemma + qwen): excluded by the dedicated-box rule, so
	// gemma has zero candidates and zero capacity rejections while the fleet
	// still serves it.
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
		{ID: qwen, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	markOnlyProviderRoutable(t, reg)

	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body = %s", status, body)
	}
	if retryAfter == "" {
		t.Fatal("429 missing Retry-After header")
	}

	decisions := findMetrics(drainMetrics(), "outcome:dedicated_capacity_429")
	if len(decisions) == 0 {
		t.Fatal("no routing.decisions packet with outcome:dedicated_capacity_429")
	}
	if !strings.Contains(decisions[0], "reason:dedicated") {
		t.Fatalf("decision packet = %s, want reason:dedicated tag", decisions[0])
	}
}
