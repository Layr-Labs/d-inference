package api

// Retry-After single-source tests: Little's law from the warm-pool snapshot,
// the legacy queue-depth fallback, caller floors (provider hint / TTFT
// overage / model shed), the #799 distress floor, the single [2,60] pre-jitter
// band and the deterministic per-request jitter.

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestLittlesLawRetryAfterSeconds pins the formula with concrete numbers:
// wait = ceil((queuePos + 1) × E[S] / C), C = warm × qualityConcurrency.
func TestLittlesLawRetryAfterSeconds(t *testing.T) {
	cases := []struct {
		name     string
		snap     registry.WarmPoolSnapshot
		queuePos int
		want     int
		wantOK   bool
		wantBase int // after the single [2,60] clamp
	}{
		// 1000 × 3 = 3000 concurrent, 20s each, 32 queued: 33 × 20 / 3000 = 0.22s → 1s → floor 2.
		{"big fleet full queue", registry.WarmPoolSnapshot{WarmProviders: 1000, QualityConcurrency: 3, ServiceTime: 20 * time.Second}, 32, 1, true, 2},
		// 5 × 1 = 5 concurrent, 20s each, 32 queued: 33 × 20 / 5 = 132s → capped at 60.
		{"niche fleet full queue caps", registry.WarmPoolSnapshot{WarmProviders: 5, QualityConcurrency: 1, ServiceTime: 20 * time.Second}, 32, 132, true, 60},
		// 5 × 1, empty queue: 1 × 20 / 5 = 4s.
		{"niche fleet empty queue", registry.WarmPoolSnapshot{WarmProviders: 5, QualityConcurrency: 1, ServiceTime: 20 * time.Second}, 0, 4, true, 4},
		// 50 × 2 = 100 concurrent, 20s, 32 queued: 33 × 20 / 100 = 6.6s → 7s.
		{"mid fleet", registry.WarmPoolSnapshot{WarmProviders: 50, QualityConcurrency: 2, ServiceTime: 20 * time.Second}, 32, 7, true, 7},
		// gemma-shaped prod pool: 32 × 2 slots, E[S] ~5s, empty queue → 1s → floor 2 (the legacy floor is kept).
		{"prod-shaped pool empty queue keeps the 2s floor", registry.WarmPoolSnapshot{WarmProviders: 32, QualityConcurrency: 2, ServiceTime: 5 * time.Second}, 0, 1, true, 2},
		{"negative position treated as 0", registry.WarmPoolSnapshot{WarmProviders: 5, QualityConcurrency: 1, ServiceTime: 20 * time.Second}, -3, 4, true, 4},
		{"no warm providers", registry.WarmPoolSnapshot{WarmProviders: 0, QualityConcurrency: 3, ServiceTime: 20 * time.Second}, 0, 0, false, 0},
		{"no service time", registry.WarmPoolSnapshot{WarmProviders: 10, QualityConcurrency: 3}, 0, 0, false, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := littlesLawRetryAfterSeconds(tc.snap, tc.queuePos)
			if ok != tc.wantOK || got != tc.want {
				t.Fatalf("littlesLaw = (%d, %v), want (%d, %v)", got, ok, tc.want, tc.wantOK)
			}
			if ok {
				if base := clampRetryAfter(got); base != tc.wantBase {
					t.Fatalf("clamped base = %d, want %d", base, tc.wantBase)
				}
			}
		})
	}
}

// TestRetryAfterBaseSeconds_LegacyFallbackAndFloors: without a warm-pool
// snapshot the pre-existing queue-depth heuristic answers verbatim (2 on an
// empty queue, 3/queued clamped to 30); caller floors raise it; the single
// band clamps it to [2, 60].
func TestRetryAfterBaseSeconds_LegacyFallbackAndFloors(t *testing.T) {
	srv, _ := testServer(t)
	cases := []struct {
		name         string
		queuePos     int
		floorSeconds int
		want         int
		wantSource   retryAfterSource
	}{
		{"empty queue", 0, 0, 2, retryAfterSourceLegacy},
		{"five queued", 5, 0, 15, retryAfterSourceLegacy},
		{"full legacy queue clamps at 30", 32, 0, 30, retryAfterSourceLegacy},
		{"provider hint floors", 0, 11, 11, retryAfterSourceFloor},
		{"floor below estimate is ignored", 5, 4, 15, retryAfterSourceLegacy},
		{"floor clamps to the single band", 0, 90, 60, retryAfterSourceFloor},
		{"model shed floor", 0, modelShedRetryAfterFloorSeconds, 30, retryAfterSourceFloor},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, source := srv.retryAfterBaseSecondsWithSource("unobserved-model", tc.queuePos, tc.floorSeconds)
			if got != tc.want || source != tc.wantSource {
				t.Fatalf("base(%d, %d) = (%d, %s), want (%d, %s)", tc.queuePos, tc.floorSeconds, got, source, tc.want, tc.wantSource)
			}
		})
	}
	if got := srv.distressFloorSeconds(); got != 0 {
		t.Fatalf("distressFloorSeconds = %d on a healthy coordinator, want 0", got)
	}
}

// TestRetryAfterBaseSeconds_DistressFloor: the #799 distress term is the
// same ceil(EWMA s) × 5 capped at 60 that estimateRetryAfter shipped, applied
// as a floor under every writer — including the provider hint path, where a
// 3 s feasible_after hint used to REPLACE the 60 s distress answer.
func TestRetryAfterBaseSeconds_DistressFloor(t *testing.T) {
	srv, _ := testServer(t)
	srv.noteAttempt0RouteLatency(4600 * time.Millisecond) // the incident's route p50
	if got := srv.distressFloorSeconds(); got != 25 {
		t.Fatalf("distressFloorSeconds = %d, want 25 (ceil(4.6) × 5)", got)
	}
	got, source := srv.retryAfterBaseSecondsWithSource("m", 0, 0)
	if got != 25 || source != retryAfterSourceDistress {
		t.Fatalf("base under distress = (%d, %s), want (25, distress)", got, source)
	}
	// Provider hint 3 s under EWMA 6 s: the hint is a floor, the distress
	// floor (30) wins — never the bare hint.
	srv2, _ := testServer(t)
	srv2.noteAttempt0RouteLatency(6 * time.Second)
	if got := srv2.retryAfterBaseSeconds("m", 0, 3); got < 30 {
		t.Fatalf("hint 3s under a 6s route EWMA = %d, want >= 30 (the distress floor)", got)
	}
	// A hint above distress still floors upward.
	if got := srv2.retryAfterBaseSeconds("m", 0, 45); got != 45 {
		t.Fatalf("hint 45s under distress 30 = %d, want 45", got)
	}
	// Cap: 90 s EWMA → 450 → 60, and the TTFT path no longer re-clamps it to 30.
	srv3, _ := testServer(t)
	srv3.noteAttempt0RouteLatency(90 * time.Second)
	if got := srv3.estimateTTFTRetryAfter("m", "fixed-key", 8*time.Second, 5*time.Second); got < 60 {
		t.Fatalf("TTFT Retry-After under capped distress = %d, want >= 60 (was clamped to 30)", got)
	}
}

// TestRetryAfterJitter_Band: 100 request ids over a base of 12 give at least
// three distinct answers, all within [base, 1.5 × base]; the same id always
// gets the same answer; a base too small to jitter (1, 2) is left alone.
func TestRetryAfterJitter_Band(t *testing.T) {
	const base = 12
	seen := map[int]int{}
	for i := 0; i < 100; i++ {
		id := "req-" + strconv.Itoa(i)
		add := retryAfterJitter(base, id)
		if add < 0 || add > base/2 {
			t.Fatalf("jitter(%d, %q) = %d, want within [0, %d]", base, id, add, base/2)
		}
		if again := retryAfterJitter(base, id); again != add {
			t.Fatalf("jitter(%d, %q) not deterministic: %d then %d", base, id, add, again)
		}
		seen[base+add]++
	}
	if len(seen) < 3 {
		t.Fatalf("100 request ids produced only %d distinct Retry-After values (%v); want >= 3", len(seen), seen)
	}
	for _, base := range []int{1, 2} {
		if add := retryAfterJitter(base, "any"); add != 0 {
			t.Fatalf("jitter(%d) = %d, want 0 (a +0..50%% band on %ds has no whole second)", base, add, base)
		}
	}
	// An empty id draws a random key but stays inside the band; the post-
	// jitter ceiling is 1.5 × 60 = 90.
	for i := 0; i < 50; i++ {
		if add := retryAfterJitter(retryAfterMaxSeconds, ""); add < 0 || add > 30 {
			t.Fatalf("random jitter(60) = %d, want within [0, 30]", add)
		}
	}
	// The jitter key is the coordinator-minted id, never the client's
	// X-Request-ID echo.
	srv, _ := testServer(t)
	var key string
	h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key = retryAfterJitterKey(r.Context())
	}))
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	req.Header.Set("X-Request-ID", "client-constant")
	h.ServeHTTP(httptest.NewRecorder(), req)
	if key == "" || key == "client-constant" {
		t.Fatalf("jitter key = %q, want a coordinator-minted id", key)
	}
	if got := retryAfterJitterKey(context.Background()); got != "" {
		t.Fatalf("jitter key without middleware = %q, want empty (random jitter)", got)
	}
}

// TestRetryAfterSeconds_WrappersShareTheSource: estimateRetryAfter is the
// exact pre-jitter base; every writer-facing wrapper lands inside
// [base, 1.5 × base] of the shared source, with the TTFT overage and the
// model-shed floor honoured.
func TestRetryAfterSeconds_WrappersShareTheSource(t *testing.T) {
	srv, st := testServer(t)
	const model = "wrapper-model"
	for i := 0; i < 5; i++ {
		if err := srv.registry.Queue().Enqueue(&registry.QueuedRequest{RequestID: "q-" + strconv.Itoa(i), Model: model}); err != nil {
			t.Fatal(err)
		}
	}
	assertBand := func(name string, got, base int) {
		t.Helper()
		if got < base || got > base+base/2 {
			t.Fatalf("%s = %d, want within [%d, %d]", name, got, base, base+base/2)
		}
	}
	if got := srv.estimateRetryAfter(model); got != 15 {
		t.Fatalf("estimateRetryAfter(5 queued) = %d, want the exact pre-jitter base 15", got)
	}
	// TTFT overage 3s < 15s queue estimate: the estimate wins.
	assertBand("estimateTTFTRetryAfter(overage 3s)", srv.estimateTTFTRetryAfter(model, "", 8*time.Second, 5*time.Second), 15)
	// TTFT overage 40s > estimate: the overage floors.
	assertBand("estimateTTFTRetryAfter(overage 40s)", srv.estimateTTFTRetryAfter(model, "", 45*time.Second, 5*time.Second), 40)
	// Model shed: the 30s floor beats the 15s estimate; header and ledger agree.
	srv.SetRejectModels(map[string]bool{model: true})
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
	if !srv.shedIfModelRejected(w, r, map[string]any{}, selfRoutePolicy{}, model, model, false, 10, 64, false, false) {
		t.Fatal("shedIfModelRejected = false, want true")
	}
	got, err := strconv.Atoi(w.Header().Get("Retry-After"))
	if err != nil {
		t.Fatalf("model shed Retry-After = %q, want integer seconds", w.Header().Get("Retry-After"))
	}
	assertBand("model shed Retry-After", got, modelShedRetryAfterFloorSeconds)
	waitForRejectionCount(t, srv, 1)
	if recs := st.RejectionRecordsSince(time.Time{}); recs[0].RetryAfterMs != got*1000 {
		t.Fatalf("ledger retryAfterMs = %d, header = %d s: the two must come from one value", recs[0].RetryAfterMs, got)
	}
	// 503 writer.
	w = httptest.NewRecorder()
	srv.writeServiceUnavailable(w, r, model)
	if got, err := strconv.Atoi(w.Header().Get("Retry-After")); err != nil || got < 15 || got > 22 {
		t.Fatalf("writeServiceUnavailable Retry-After = %q, want within [15, 22]", w.Header().Get("Retry-After"))
	}
}

// TestRetryAfterSingleSource_NoLiteralHeaders is the grep pin: no non-test
// file in this package hard-codes a Retry-After value or computes one from
// the pre-jitter estimateRetryAfter — every writer goes through
// retryAfterSeconds (or a value it already produced, e.g. preContentTerminal
// and the rate-limit writer's ceil+jitter of the bucket deficit).
func TestRetryAfterSingleSource_NoLiteralHeaders(t *testing.T) {
	literal := regexp.MustCompile(`Set\("Retry-After",\s*"`)
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatal(err)
		}
		if literal.Match(src) {
			t.Errorf("%s hard-codes a Retry-After literal; route it through retryAfterSeconds", name)
		}
		if name != "consumer.go" && strings.Contains(string(src), "estimateRetryAfter(") {
			t.Errorf("%s calls the pre-jitter estimateRetryAfter; writers must use retryAfterSeconds", name)
		}
	}
}

// ---------------------------------------------------------------------------
// Live: a saturated 1-slot fleet, a full queue, and the 429's Retry-After.
// ---------------------------------------------------------------------------

// queuedFleetHarness boots a coordinator with one REAL WebSocket provider whose
// heartbeat reports a saturated token budget, so every request for model
// capacity-spills to the coordinator queue (queue-before-shed on, cold dispatch
// off). Returns the server, store, registry and test server.
func queuedFleetHarness(t *testing.T, ctx context.Context, cfg ServerConfig, model string) (*Server, *store.MemoryStore, *registry.Registry, *httptest.Server) {
	t.Helper()
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, cfg, logger)
	t.Cleanup(srv.Close)
	srv.challengeInterval = time.Hour
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: model, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "done") })
	p := markOnlyProviderRoutable(t, reg)
	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			MaxConcurrency:        1,
			ActiveTokenBudgetUsed: 950,
			ActiveTokenBudgetMax:  1_000,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
	})
	return srv, st, reg, ts
}

type chatResult struct {
	status     int
	body       string
	retryAfter string
	err        error
}

func chatRequestWithID(ctx context.Context, baseURL, model, requestID string) chatResult {
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":64}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return chatResult{err: err}
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	if requestID != "" {
		req.Header.Set("X-Request-ID", requestID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return chatResult{err: err}
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return chatResult{status: resp.StatusCode, body: string(data), retryAfter: resp.Header.Get("Retry-After")}
}

// TestRetryAfterHeader_QueueFullLive: with the single slot saturated and a
// 1-deep queue already holding a request, overflow requests get queue_full
// 429s whose Retry-After is the shared source — legacy base 3 s (one queued,
// no warm-pool snapshot) plus the jitter keyed on the coordinator-minted id,
// so every answer lands in [3, 4] and the rejection ledger carries the same
// value the header did.
func TestRetryAfterHeader_QueueFullLive(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "retry-after-live-model"
	srv, st, reg, ts := queuedFleetHarness(t, ctx, ServerConfig{}, model)
	reg.SetQueue(registry.NewRequestQueue(1, 10*time.Second))

	// Park one request in the (1-deep) queue.
	parkedCtx, cancelParked := context.WithCancel(ctx)
	defer cancelParked()
	parked := make(chan chatResult, 1)
	go func() { parked <- chatRequestWithID(parkedCtx, ts.URL, model, "") }()
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		return reg.Queue().QueueSize(model) >= 1
	})
	select {
	case res := <-parked:
		t.Fatalf("parked request returned %d early; body=%s", res.status, res.body)
	default:
	}

	const base = 3
	headers := map[int]int{}
	for i := 0; i < 6; i++ {
		res := chatRequestWithID(ctx, ts.URL, model, "client-constant-id")
		if res.err != nil {
			t.Fatalf("overflow request %d: %v", i, res.err)
		}
		if res.status != http.StatusTooManyRequests {
			t.Fatalf("overflow request %d status = %d, want 429 queue_full; body=%s", i, res.status, res.body)
		}
		if !strings.Contains(res.body, "queue is full") {
			t.Fatalf("overflow request %d body is not the queue_full rejection: %s", i, res.body)
		}
		got, err := strconv.Atoi(res.retryAfter)
		if err != nil {
			t.Fatalf("overflow request %d Retry-After = %q, want integer seconds", i, res.retryAfter)
		}
		if got < base || got > base+base/2 {
			t.Fatalf("overflow request %d Retry-After = %d, want within [%d, %d] (legacy base + jitter)", i, got, base, base+base/2)
		}
		headers[got]++
	}
	t.Logf("queue_full Retry-After distribution over 6 overflow requests: %v", headers)
	waitForRejectionCount(t, srv, 6)
	for _, rec := range st.RejectionRecordsSince(time.Time{}) {
		if rec.ReasonCode != "queue_full" {
			continue
		}
		if rec.RetryAfterMs < base*1000 || rec.RetryAfterMs > (base+base/2)*1000 {
			t.Fatalf("ledger retryAfterMs = %d, want within the header band", rec.RetryAfterMs)
		}
	}
	cancelParked()
}

// TestRetryAfterFollowsRealWarmPoolTick drives a REAL warm-pool controller
// planning tick over the live WS provider (no seeded snapshot) and checks that
// the Retry-After source agrees with Little's law applied to the snapshot the
// controller actually produced, at several queue positions.
func TestRetryAfterFollowsRealWarmPoolTick(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "warm-pool-tick-model"
	srv, _, reg, _ := queuedFleetHarness(t, ctx, ServerConfig{}, model)

	// Before any tick: legacy answers.
	if got := srv.retryAfterBaseSeconds(model, 0, 0); got != 2 {
		t.Fatalf("pre-tick base = %d, want legacy 2", got)
	}

	reg.ConfigureWarmPool(registry.WarmPoolConfig{
		Enabled:                    true,
		Interval:                   time.Second,
		FallbackQualityConcurrency: 4,
		AssumedPromptTokens:        512,
		AssumedCompletionTokens:    256,
		MaxLoadsPerTick:            1,
		MaxGlobalPendingLoads:      10,
	})
	reg.TriggerWarmPool()
	snap, ok := reg.LatestWarmPoolSnapshotFor(model)
	if !ok {
		t.Fatal("no warm-pool snapshot for the model after a real tick")
	}
	c := snap.WarmProviders * snap.QualityConcurrency
	if c <= 0 || snap.ServiceTime <= 0 {
		t.Fatalf("snapshot has no usable capacity: %+v", snap)
	}
	for _, queuePos := range []int{0, 1, 32} {
		littles, ok := littlesLawRetryAfterSeconds(snap, queuePos)
		if !ok {
			t.Fatalf("littlesLaw not ok for %+v", snap)
		}
		want := clampRetryAfter(littles)
		if got := srv.retryAfterBaseSeconds(model, queuePos, 0); got != want {
			t.Fatalf("base(queuePos=%d) = %d, want %d from snapshot C=%d E[S]=%v", queuePos, got, want, c, snap.ServiceTime)
		}
	}
	// A stale snapshot is not trusted.
	if _, ok := reg.LatestWarmPoolSnapshotFor("never-seen"); ok {
		t.Fatal("LatestWarmPoolSnapshotFor returned a snapshot for an unobserved model")
	}
}
