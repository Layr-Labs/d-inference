package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// minimalChatBody is a small, well-formed chat-completions body. The drain gate
// is the outermost wrapper and short-circuits before the body is read, so its
// exact contents don't matter — it only needs to look like a real request.
const minimalChatBody = `{"model":"test","messages":[{"role":"user","content":"hi"}]}`

// doReq drives a request through the full server handler (CORS → recover →
// logging → mux → middleware chain) — the real HTTP path, no mocks.
func doReq(srv *Server, method, path, auth, body string) *httptest.ResponseRecorder {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	if auth != "" {
		r.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, r)
	return w
}

// (a) POST /v1/admin/drain is admin-gated. The route is wrapped with requireAuth
// (the canonical admin-endpoint pattern), so unauthenticated callers get 401
// (missing/invalid credentials) and authenticated-but-non-admin callers get 403.
// Either way a rejected call must not flip drain state.
func TestAdminDrain_RequiresAdminAuth(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")

	// No bearer at all → requireAuth rejects with 401 (missing credentials).
	if w := doReq(srv, http.MethodPost, "/v1/admin/drain", "", ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("no-bearer status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	// Wrong bearer (not the admin key, not a valid API key) → 401 from requireAuth;
	// the constant-time admin-key compare must not match.
	if w := doReq(srv, http.MethodPost, "/v1/admin/drain", "Bearer wrong-key", ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("wrong-bearer status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	// A rejected admin call must not have changed drain state.
	if srv.IsDraining() {
		t.Fatal("IsDraining() = true after a rejected admin call, want false")
	}
}

// (a) A Privy admin (email in the admin list) is authorized via the Privy branch
// of isAdminAuthorized — the path that was dead while the route was registered
// raw with no middleware to populate auth.UserFromContext. We exercise the
// handler with the user already in context (what requireAuth does after verifying
// the JWT), so the test is deterministic and needs no Privy verifier.
func TestAdminDrain_PrivyAdminAuthorized(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")
	srv.SetAdminEmails([]string{"admin@darkbloom.ai"})

	admin := &store.User{AccountID: "acct-admin", Email: "admin@darkbloom.ai"}
	r := withPrivyUser(httptest.NewRequest(http.MethodPost, "/v1/admin/drain", nil), admin)
	w := httptest.NewRecorder()
	srv.handleAdminDrain(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("privy-admin status = %d, want %d (body=%s)", w.Code, http.StatusOK, w.Body.String())
	}
	if !srv.IsDraining() {
		t.Fatal("IsDraining() = false after privy-admin drain, want true")
	}
}

// (a) A valid but non-admin identity (Privy user whose email is NOT in the admin
// list) is rejected with 403 by isAdminAuthorized, proving authentication alone
// (passing requireAuth) is not sufficient — admin authorization still applies.
func TestAdminDrain_NonAdminForbidden(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")
	srv.SetAdminEmails([]string{"admin@darkbloom.ai"})

	user := &store.User{AccountID: "acct-user", Email: "nobody@example.com"}
	r := withPrivyUser(httptest.NewRequest(http.MethodPost, "/v1/admin/drain", nil), user)
	w := httptest.NewRecorder()
	srv.handleAdminDrain(w, r)

	if w.Code != http.StatusForbidden {
		t.Fatalf("non-admin status = %d, want %d (body=%s)", w.Code, http.StatusForbidden, w.Body.String())
	}
	if srv.IsDraining() {
		t.Fatal("IsDraining() = true after a non-admin call, want false")
	}
}

// (a) POST /v1/admin/drain with Bearer test-key returns 200 and flips
// IsDraining()→true; an explicit {"draining": false} body un-drains.
func TestAdminDrain_SetAndUndrain(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")

	// Empty body defaults to draining=true.
	w := doReq(srv, http.MethodPost, "/v1/admin/drain", "Bearer test-key", "")
	if w.Code != http.StatusOK {
		t.Fatalf("drain status = %d, want %d (body=%s)", w.Code, http.StatusOK, w.Body.String())
	}
	if !srv.IsDraining() {
		t.Fatal("IsDraining() = false after drain, want true")
	}
	var got struct {
		Draining bool `json:"draining"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal drain response: %v", err)
	}
	if !got.Draining {
		t.Fatalf("response draining = false, want true (body=%s)", w.Body.String())
	}

	// Explicit {"draining": false} un-drains (rollback path).
	w = doReq(srv, http.MethodPost, "/v1/admin/drain", "Bearer test-key", `{"draining": false}`)
	if w.Code != http.StatusOK {
		t.Fatalf("undrain status = %d, want %d", w.Code, http.StatusOK)
	}
	if srv.IsDraining() {
		t.Fatal("IsDraining() = true after undrain, want false")
	}
}

// (a) Regression (DAR-327 Phase 1 review): the un-drain rollback must work even
// when {"draining":false} arrives with chunked transfer-encoding / unknown
// Content-Length (ContentLength == -1). The old `ContentLength > 0` guard skipped
// the body for such requests and silently defaulted to draining=true, so a
// rollback sent without a Content-Length would fail to un-drain.
func TestAdminDrain_UndrainChunkedBodyNoContentLength(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")

	// Start from the state a rollback must clear.
	srv.SetDraining(true)
	if !srv.IsDraining() {
		t.Fatal("precondition: IsDraining() should be true before rollback")
	}

	// Build a chunked POST with no Content-Length. An io.NopCloser body is not
	// one of httptest's length-known types, so ContentLength is unset; we also
	// force ContentLength = -1 and chunked transfer-encoding to make the
	// unknown-length path explicit and exercise the exact regression.
	body := io.NopCloser(strings.NewReader(`{"draining":false}`))
	r := httptest.NewRequest(http.MethodPost, "/v1/admin/drain", body)
	r.ContentLength = -1
	r.TransferEncoding = []string{"chunked"}
	r.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("chunked undrain status = %d, want %d (body=%s)", w.Code, http.StatusOK, w.Body.String())
	}
	if srv.IsDraining() {
		t.Fatal(`IsDraining() = true after chunked {"draining":false}, want false`)
	}
	var got struct {
		Draining bool `json:"draining"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal undrain response: %v", err)
	}
	if got.Draining {
		t.Fatalf("response draining = true, want false (body=%s)", w.Body.String())
	}
}

// (b) While draining, a NEW POST /v1/chat/completions is rejected at the gate
// with 429 + Retry-After, before dispatch, and does not leak the in-flight count.
func TestDrainGate_RejectsNewInferenceWhileDraining(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetDraining(true)

	w := doReq(srv, http.MethodPost, "/v1/chat/completions", "", minimalChatBody)
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d (body=%s)", w.Code, http.StatusTooManyRequests, w.Body.String())
	}
	ra := w.Header().Get("Retry-After")
	if ra == "" {
		t.Fatal("Retry-After header missing on drain 429")
	}
	if secs, err := strconv.Atoi(ra); err != nil || secs < 1 {
		t.Fatalf("Retry-After = %q, want a positive integer seconds value", ra)
	}
	// The gate rejected before incrementing — nothing is in flight.
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d after a rejected request, want 0", n)
	}
}

// (c) GET /readyz reports 200/{ready:true} normally and 503/{draining:true}
// after drain — unauthenticated either way.
func TestReadyz_ReflectsDrainState(t *testing.T) {
	srv, _ := testServer(t)

	w := doReq(srv, http.MethodGet, "/readyz", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("ready status = %d, want %d", w.Code, http.StatusOK)
	}
	var ready readinessResponse
	if err := json.Unmarshal(w.Body.Bytes(), &ready); err != nil {
		t.Fatalf("unmarshal readyz: %v", err)
	}
	if ready.Draining || !ready.Ready {
		t.Fatalf("readyz = %+v, want {draining:false, ready:true}", ready)
	}

	srv.SetDraining(true)
	w = doReq(srv, http.MethodGet, "/readyz", "", "")
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("draining status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
	var draining readinessResponse
	if err := json.Unmarshal(w.Body.Bytes(), &draining); err != nil {
		t.Fatalf("unmarshal readyz (draining): %v", err)
	}
	if !draining.Draining || draining.Ready {
		t.Fatalf("readyz = %+v, want {draining:true, ready:false}", draining)
	}
}

// (c) GET /health is a LIVENESS probe: it stays 200 even while draining (it just
// reports draining:true in the body). It must NOT flip to 503, because EigenCloud's
// Caddy health-checks its single coordinator upstream on /health — a 503 would mark
// the only backend down and make the admin/rollback endpoints and /readyz
// unreachable. Drain/readiness is exposed on /readyz (see above), not /health.
func TestHealth_ReflectsDrainState(t *testing.T) {
	srv, _ := testServer(t)

	// Healthy: 200 + status ok, no draining flag.
	w := doReq(srv, http.MethodGet, "/health", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("health status = %d, want %d", w.Code, http.StatusOK)
	}
	var h struct {
		Status   string `json:"status"`
		Draining bool   `json:"draining"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &h); err != nil {
		t.Fatalf("unmarshal health: %v", err)
	}
	if h.Status != "ok" || h.Draining {
		t.Fatalf("health = %+v, want {status:ok, draining:false}", h)
	}

	// Draining: stays 200 (liveness) but reports draining:true for observability.
	srv.SetDraining(true)
	w = doReq(srv, http.MethodGet, "/health", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("draining health status = %d, want %d (liveness must stay up)", w.Code, http.StatusOK)
	}
	if err := json.Unmarshal(w.Body.Bytes(), &h); err != nil {
		t.Fatalf("unmarshal health (draining): %v", err)
	}
	if !h.Draining {
		t.Fatalf("health = %+v, want draining:true", h)
	}
}

// (d) GET /v1/models/capacity is drain-aware: while draining it advertises zero
// models + draining:true (and is not cached) so OpenRouter-style routers stop
// selecting this instance instead of dispatching and then getting drain 429s.
func TestModelsCapacity_EmptyWhileDraining(t *testing.T) {
	srv, _ := testServer(t)

	srv.SetDraining(true)
	w := doReq(srv, http.MethodGet, "/v1/models/capacity", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("capacity status = %d, want %d", w.Code, http.StatusOK)
	}
	var resp struct {
		Models   []json.RawMessage `json:"models"`
		Draining bool              `json:"draining"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal capacity: %v", err)
	}
	if !resp.Draining {
		t.Fatalf("capacity draining = false, want true (body=%s)", w.Body.String())
	}
	if len(resp.Models) != 0 {
		t.Fatalf("capacity models = %d, want 0 while draining", len(resp.Models))
	}

	// Un-drain must be reflected immediately — the draining response is not cached.
	// Use a fresh struct: the non-draining body omits the draining field (omitempty),
	// and json.Unmarshal leaves absent fields untouched, so reusing resp would keep
	// the previous true.
	srv.SetDraining(false)
	w = doReq(srv, http.MethodGet, "/v1/models/capacity", "", "")
	var resp2 struct {
		Models   []json.RawMessage `json:"models"`
		Draining bool              `json:"draining"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp2); err != nil {
		t.Fatalf("unmarshal capacity (undrained): %v", err)
	}
	if resp2.Draining {
		t.Fatal("capacity draining = true after un-drain, want false (stale cache?)")
	}
}

// (d) The in-flight counter increments/decrements back to 0, and SetDraining is
// deterministic. Exercises the real Server methods directly (same package).
func TestInflight_AndSetDrainingAreDeterministic(t *testing.T) {
	srv, _ := testServer(t)

	if n := srv.Inflight(); n != 0 {
		t.Fatalf("initial Inflight() = %d, want 0", n)
	}
	if n := srv.incInflight(); n != 1 {
		t.Fatalf("after inc Inflight() = %d, want 1", n)
	}
	if n := srv.Inflight(); n != 1 {
		t.Fatalf("Inflight() = %d, want 1", n)
	}
	if n := srv.decInflight(); n != 0 {
		t.Fatalf("after dec Inflight() = %d, want 0", n)
	}

	if srv.IsDraining() {
		t.Fatal("IsDraining() = true by default, want false")
	}
	srv.SetDraining(true)
	if !srv.IsDraining() {
		t.Fatal("IsDraining() = false after SetDraining(true)")
	}
	srv.SetDraining(false)
	if srv.IsDraining() {
		t.Fatal("IsDraining() = true after SetDraining(false)")
	}

	// A full request through the gate must leave the counter back at 0 even when
	// the request is rejected downstream (here: 401 from requireAuth).
	_ = doReq(srv, http.MethodPost, "/v1/chat/completions", "", minimalChatBody)
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d after a completed request, want 0", n)
	}
}

// (e) Regression: when NOT draining, an inference request passes the gate (it is
// not 429'd by the gate) and proceeds into the normal chain — here it reaches
// requireAuth and gets 401, proving the gate let it through.
func TestDrainGate_PassesThroughWhenNotDraining(t *testing.T) {
	srv, _ := testServer(t)

	if srv.IsDraining() {
		t.Fatal("precondition: server should not be draining")
	}
	w := doReq(srv, http.MethodPost, "/v1/chat/completions", "", minimalChatBody)
	if w.Code == http.StatusTooManyRequests {
		t.Fatalf("gate returned 429 while not draining (body=%s)", w.Body.String())
	}
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d (passed gate, rejected by auth)", w.Code, http.StatusUnauthorized)
	}
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d after request, want 0", n)
	}
}

// (b) Concurrency/-race: hammering the gate while SetDraining flips on and off
// must never leak the in-flight counter and it must settle back to 0 once traffic
// stops. Run with -race. Also asserts the gate's count-before-check invariant:
// every request that reaches next() was already counted in-flight, so an external
// reader (e.g. /readyz) can never observe a running request as inflight:0.
func TestDrainGate_ConcurrentNoInflightLeak(t *testing.T) {
	srv, _ := testServer(t)

	var ranUncounted atomic.Int64
	gate := srv.drainGate(func(w http.ResponseWriter, r *http.Request) {
		// We are past the gate; it must have counted us before calling next.
		if srv.Inflight() < 1 {
			ranUncounted.Add(1)
		}
		w.WriteHeader(http.StatusOK)
	})

	const workers = 64
	const iters = 50

	// Flip draining on/off concurrently with the traffic until told to stop.
	stop := make(chan struct{})
	var flipper sync.WaitGroup
	flipper.Add(1)
	go func() {
		defer flipper.Done()
		for {
			select {
			case <-stop:
				return
			default:
				srv.SetDraining(true)
				srv.SetDraining(false)
			}
		}
	}()

	var work sync.WaitGroup
	for i := 0; i < workers; i++ {
		work.Add(1)
		go func() {
			defer work.Done()
			for j := 0; j < iters; j++ {
				w := httptest.NewRecorder()
				r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
				gate(w, r)
			}
		}()
	}
	work.Wait()
	close(stop)
	flipper.Wait()

	// No request is running, so inflight must be 0 regardless of the final flag.
	srv.SetDraining(false)
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d after all requests, want 0 (counter leak)", n)
	}
	if n := ranUncounted.Load(); n != 0 {
		t.Fatalf("%d requests reached next() while Inflight()<1 (count-before-check violated)", n)
	}
}

// (e) DrainGraceFromEnv parses EIGENINFERENCE_DRAIN_GRACE, falling back to the
// default for unset/empty/invalid/negative values and honoring an explicit "0"
// (no wait — Shutdown is called immediately).
func TestDrainGraceFromEnv(t *testing.T) {
	cases := []struct {
		name string
		val  string
		want time.Duration
	}{
		{"unset", "", DefaultDrainGrace},
		{"valid_seconds", "90s", 90 * time.Second},
		{"valid_minutes", "2m", 2 * time.Minute},
		{"zero_disables_wait", "0", 0},
		{"invalid_falls_back", "not-a-duration", DefaultDrainGrace},
		{"negative_falls_back", "-5s", DefaultDrainGrace},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_DRAIN_GRACE", tc.val)
			if got := DrainGraceFromEnv(); got != tc.want {
				t.Fatalf("DrainGraceFromEnv() = %v, want %v", got, tc.want)
			}
		})
	}
}

// (e) WaitForInflightZero returns immediately when nothing is in flight, times
// out (false) while a request is still in flight, and returns true once the count
// drops to 0 before the deadline.
func TestWaitForInflightZero(t *testing.T) {
	srv, _ := testServer(t)

	// Already zero → true immediately.
	if !srv.WaitForInflightZero(context.Background()) {
		t.Fatal("WaitForInflightZero() = false with inflight 0, want true")
	}

	// One in flight, short deadline → times out false.
	srv.incInflight()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if srv.WaitForInflightZero(ctx) {
		t.Fatal("WaitForInflightZero() = true while a request is in flight, want false")
	}

	// Drop to 0 from another goroutine → returns true before the deadline.
	go func() {
		time.Sleep(20 * time.Millisecond)
		srv.decInflight()
	}()
	ctx2, cancel2 := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel2()
	if !srv.WaitForInflightZero(ctx2) {
		t.Fatal("WaitForInflightZero() = false after inflight dropped to 0, want true")
	}
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d at end, want 0", n)
	}
}
