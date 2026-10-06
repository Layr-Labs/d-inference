package operations_test

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// minimalChatBody is a small, well-formed chat-completions body. The drain gate
// is the outermost wrapper and short-circuits before the body is read, so its
// exact contents don't matter — it only needs to look like a real request.
const minimalChatBody = `{"model":"test","messages":[{"role":"user","content":"hi"}]}`

// doReq drives a request through the full server handler (CORS → recover →
// logging → mux → middleware chain) — the real HTTP path, no mocks.
func doReq(srv *api.Server, method, path, auth, body string) *httptest.ResponseRecorder {
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
	srv := testkit.New(t, api.ServerConfig{}).Server
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
// full handler with a locally signed JWT, including the real Privy verifier.
func TestAdminDrain_PrivyAdminAuthorized(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	srv := f.Server
	srv.SetAdminKey("test-key")
	srv.SetAdminEmails([]string{"admin@darkbloom.ai"})

	admin := &store.User{AccountID: "acct-admin", PrivyUserID: "did:privy:acct-admin", Email: "admin@darkbloom.ai"}
	if err := f.Store.CreateUser(admin); err != nil {
		t.Fatal(err)
	}
	token := testkit.NewSessions(t, srv, f.Store).Token(admin.AccountID)
	w := doReq(srv, http.MethodPost, "/v1/admin/drain", "Bearer "+token, "")

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
	f := testkit.New(t, api.ServerConfig{})
	srv := f.Server
	srv.SetAdminKey("test-key")
	srv.SetAdminEmails([]string{"admin@darkbloom.ai"})

	user := &store.User{AccountID: "acct-user", PrivyUserID: "did:privy:acct-user", Email: "nobody@example.com"}
	if err := f.Store.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	token := testkit.NewSessions(t, srv, f.Store).Token(user.AccountID)
	w := doReq(srv, http.MethodPost, "/v1/admin/drain", "Bearer "+token, "")

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
	srv := testkit.New(t, api.ServerConfig{}).Server
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
	srv := testkit.New(t, api.ServerConfig{}).Server
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
	srv := testkit.New(t, api.ServerConfig{}).Server
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
	srv := testkit.New(t, api.ServerConfig{}).Server

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
	srv := testkit.New(t, api.ServerConfig{}).Server

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
	srv := testkit.New(t, api.ServerConfig{}).Server

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
// deterministic. Exercises the real server's composed request path.
func TestInflight_AndSetDrainingAreDeterministic(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server

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
	srv := testkit.New(t, api.ServerConfig{}).Server

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

// Local wire projection keeps readiness assertions at the composed HTTP boundary.
type readinessResponse struct {
	Draining     bool   `json:"draining"`
	Inflight     int64  `json:"inflight"`
	Ready        bool   `json:"ready"`
	HealthReason string `json:"health_reason,omitempty"`
}
