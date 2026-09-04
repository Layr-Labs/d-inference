package api

// First-content clock anchor (T10-09): RequestTiming.ReceivedAt is the HTTP
// ingress instant stamped by loggingMiddleware, not the handler-entry
// time.Now() that followed drainGate → requireAuth → rateLimitConsumer →
// sealedTransport. The pre-handler segment is microseconds warm and
// milliseconds on an API-key cache miss or a large sealed body, and every one
// of them was silently missing from the request-absolute clock.

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestIngressStartFromContext: the middleware stamps the ingress instant on
// every request whether or not the profiler is on (requestMeta stays
// profiler-gated), and a context the middleware never saw falls back to now.
func TestIngressStartFromContext(t *testing.T) {
	t.Setenv(envProfiler, "off")
	srv, _ := testServer(t)
	before := time.Now()
	var seen time.Time
	h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requestMetaFromContext(r.Context()) != nil {
			t.Error("requestMeta must stay profiler-gated")
		}
		time.Sleep(20 * time.Millisecond)
		seen = ingressStartFromContext(r.Context())
	}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))
	after := time.Now()
	if seen.Before(before) || seen.After(after.Add(-20*time.Millisecond)) {
		t.Fatalf("ingress start %v not inside [%v, %v-20ms]: the middleware must stamp its own t0", seen, before, after)
	}

	// No middleware: the fallback is "now", never zero.
	fallbackBefore := time.Now()
	got := ingressStartFromContext(context.Background())
	if got.Before(fallbackBefore) || got.After(time.Now()) {
		t.Fatalf("fallback ingress start = %v, want ~now", got)
	}
	if got := ingressStartFromContext(nil); got.IsZero() { //nolint:staticcheck // nil ctx is the documented fallback
		t.Fatal("nil context must fall back to now")
	}
}

// slowUserStore delays the linked-key user lookup requireAuth performs, so
// the pre-handler segment of a real request is a deterministic 300 ms.
type slowUserStore struct {
	store.Store
	delay time.Duration
}

func (s *slowUserStore) GetUserByAccountID(accountID string) (*store.User, error) {
	time.Sleep(s.delay)
	return s.Store.GetUserByAccountID(accountID)
}

func (s *slowUserStore) Unwrap() store.Store { return s.Store }

// ingressClockHarness boots a coordinator over a store whose user lookup takes
// authDelay, with a linked API key so requireAuth pays that lookup, and one
// real WebSocket provider that serves every request. Returns the test server,
// the bearer key, the memory store (route rows) and the provider handle
// (dispatch count).
func ingressClockHarness(t *testing.T, ctx context.Context, cfg ServerConfig, authDelay time.Duration, model string) (*httptest.Server, string, *store.MemoryStore, *failoverProvider) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	mem := store.NewMemory(store.Config{AdminKey: "test-key"})
	if err := mem.CreateUser(&store.User{AccountID: "ingress-acct", PrivyUserID: "did:privy:ingress"}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	apiKey, _, err := mem.CreateAPIKey("ingress-acct", store.APIKeyCreate{Name: "ingress"})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}
	reg := registry.New(logger)
	srv := NewServer(reg, &slowUserStore{Store: mem, delay: authDelay}, cfg, logger)
	t.Cleanup(srv.Close)
	srv.challengeInterval = time.Hour
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "ingress-provider", Version: "0.8.10", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	return ts, apiKey, mem, fp
}

// finalRouteRecordFor polls the memory store until model's route row carries
// its terminal outcome (the sink merges it asynchronously) and returns it.
func finalRouteRecordFor(t *testing.T, st *store.MemoryStore, model string) store.InferenceRouteRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, rec := range st.InferenceRouteRecordsSince(time.Time{}) {
			if rec.Model == model && rec.FinalStatus != "" {
				return rec
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no terminal route record for %s", model)
	return store.InferenceRouteRecord{}
}

func ingressClockChat(t *testing.T, ctx context.Context, ts *httptest.Server, apiKey, model string) (*http.Response, string) {
	t.Helper()
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"max_tokens":32,"stream":false}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, string(data)
}

func parseXTiming(t *testing.T, resp *http.Response) types.RequestTimingDetails {
	t.Helper()
	raw := resp.Header.Get("X-Timing")
	if raw == "" {
		t.Fatal("X-Timing header missing")
	}
	var tj types.RequestTimingDetails
	if err := json.Unmarshal([]byte(raw), &tj); err != nil {
		t.Fatalf("X-Timing %q: %v", raw, err)
	}
	return tj
}

// TestFirstContentClockAnchorsAtIngressLive drives the REAL route chain
// (srv.Handler(): loggingMiddleware → drainGate → requireAuth → rateLimit →
// handler) with a 300 ms user lookup inside requireAuth and a real provider.
//
//   - With a 250 ms first-content base the clock has ALREADY expired when the
//     handler runs, so the request must be shed as a retryable 429 without a
//     dispatch. Before the change ReceivedAt was stamped at handler entry, the
//     request kept a fresh 250 ms and the provider served it (200).
//   - The parse segment keeps its handler-entry anchor in every consumer:
//     X-Timing's legacy parse_us, the inference_routes parse_ms column (and
//     therefore the inference.timing.parse_ms histogram, which reads the same
//     outcome struct) all stay ~0 while total_duration_ms, ingress-anchored,
//     carries the 300 ms. Anchoring parse on the ingress ReceivedAt turned an
//     API-key cache miss or a sealed decrypt into a "parse regression".
//   - With the profiler ON, pre_handler_us carries the 300 ms and parse_us
//     does NOT — the two segments never double-count.
//
// The media-fetch budget (media_resolve.go mediaFetchBudget) derives from the
// same ReceivedAt and therefore shrinks by the same pre-handler time — the
// arithmetic pin at the end covers that seam.
func TestFirstContentClockAnchorsAtIngressLive(t *testing.T) {
	const authDelay = 300 * time.Millisecond
	const model = "ingress-clock-model"

	t.Run("expired_at_entry_is_shed_without_dispatch", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		ts, key, _, fp := ingressClockHarness(t, ctx, ServerConfig{FirstContentDeadlineBase: 250 * time.Millisecond}, authDelay, model)
		resp, body := ingressClockChat(t, ctx, ts, key, model)
		if resp.StatusCode != http.StatusTooManyRequests {
			t.Fatalf("status = %d, want 429 (clock anchored at ingress is already spent); body=%s", resp.StatusCode, body)
		}
		// "Without a dispatch": the post-dispatch first_chunk_timeout path
		// answers the same 429 shape, so the provider must have seen nothing.
		if n := fp.dispatchCount(); n != 0 {
			t.Fatalf("provider received %d dispatch(es); an expired-at-entry request must be shed before any dispatch", n)
		}
		if resp.Header.Get("Retry-After") == "" {
			t.Fatalf("429 without Retry-After: %s", body)
		}
		if !strings.Contains(body, "rate_limit_exceeded") {
			t.Fatalf("body = %s, want the retryable rate_limit_exceeded shape", body)
		}
	})

	t.Run("parse_segment_stays_handler_anchored_in_every_consumer", func(t *testing.T) {
		t.Setenv(envProfiler, "off")
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		ts, key, st, _ := ingressClockHarness(t, ctx, ServerConfig{}, authDelay, model)
		resp, body := ingressClockChat(t, ctx, ts, key, model)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, body=%s", resp.StatusCode, body)
		}
		tj := parseXTiming(t, resp)
		if tj.ParseUs >= authDelay.Microseconds() {
			t.Fatalf("X-Timing parse_us = %d carries the %d us pre-handler segment: parse must start at handler entry", tj.ParseUs, authDelay.Microseconds())
		}
		if tj.PreHandlerUs != 0 {
			t.Fatalf("pre_handler_us = %d with the profiler off, want 0 (legacy header byte-for-byte)", tj.PreHandlerUs)
		}
		// inference_routes.parse_ms (the same outcome struct feeds the
		// inference.timing.parse_ms histogram) is handler-anchored too, while
		// total_duration_ms keeps the ingress anchor.
		rec := finalRouteRecordFor(t, st, model)
		if rec.ParseMs >= float64(authDelay.Milliseconds()) {
			t.Fatalf("route parse_ms = %.0f carries the %d ms pre-handler segment", rec.ParseMs, authDelay.Milliseconds())
		}
		if rec.TotalDurationMs < float64(authDelay.Milliseconds()) {
			t.Fatalf("route total_duration_ms = %.0f, want >= %d (ingress-anchored: the pre-handler time is part of the request's wall time)", rec.TotalDurationMs, authDelay.Milliseconds())
		}
	})

	t.Run("x_timing_never_double_counts_pre_handler_profiler_on", func(t *testing.T) {
		t.Setenv(envProfiler, "on")
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		ts, key, _, _ := ingressClockHarness(t, ctx, ServerConfig{}, authDelay, model)
		resp, body := ingressClockChat(t, ctx, ts, key, model)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, body=%s", resp.StatusCode, body)
		}
		tj := parseXTiming(t, resp)
		if tj.PreHandlerUs < authDelay.Microseconds() {
			t.Fatalf("pre_handler_us = %d, want >= %d", tj.PreHandlerUs, authDelay.Microseconds())
		}
		if tj.ParseUs >= authDelay.Microseconds() {
			t.Fatalf("parse_us = %d also carries the %d us pre-handler segment: double count", tj.ParseUs, tj.PreHandlerUs)
		}
	})

	// Media budget seam: the budget derives from ReceivedAt, so anchoring at
	// ingress shrinks it by exactly the pre-handler time.
	ingress := time.Now().Add(-authDelay)
	atIngress, _ := mediaFetchBudget(ingress, 5*time.Second)
	atEntry, _ := mediaFetchBudget(time.Now(), 5*time.Second)
	if diff := atEntry - atIngress; diff < authDelay-50*time.Millisecond || diff > authDelay+50*time.Millisecond {
		t.Fatalf("media budget shrank by %v, want ~%v (the pre-handler time)", diff, authDelay)
	}
}
