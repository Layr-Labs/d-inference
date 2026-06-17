package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
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

// (a) POST /v1/admin/drain is admin-gated: 403 without an admin bearer.
func TestAdminDrain_RequiresAdminAuth(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")

	// No bearer at all.
	if w := doReq(srv, http.MethodPost, "/v1/admin/drain", "", ""); w.Code != http.StatusForbidden {
		t.Fatalf("no-bearer status = %d, want %d", w.Code, http.StatusForbidden)
	}
	// Wrong bearer (constant-time compare must reject).
	if w := doReq(srv, http.MethodPost, "/v1/admin/drain", "Bearer wrong-key", ""); w.Code != http.StatusForbidden {
		t.Fatalf("wrong-bearer status = %d, want %d", w.Code, http.StatusForbidden)
	}
	// A rejected admin call must not have changed drain state.
	if srv.IsDraining() {
		t.Fatal("IsDraining() = true after a rejected admin call, want false")
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
