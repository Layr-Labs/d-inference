package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Tests for the runtime shed-list admin endpoints (GET/PUT
// /v1/admin/reject-models), through the real HTTP mux per repo policy.

func setupAdminRejectModels(t *testing.T) (*httptest.Server, *Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	// The store admin key doubles as a VALID (non-admin) consumer API key, so
	// the 403 leg exercises an authenticated-but-unauthorized caller.
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{AdminKey: "admin-secret"}, logger)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, srv
}

// rejectModelsCall performs a GET/PUT against /v1/admin/reject-models.
func rejectModelsCall(t *testing.T, ts *httptest.Server, method, bearer, body string) (int, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, ts.URL+"/v1/admin/reject-models", rdr)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data)
}

// TestAdminRejectModelsAuth pins the auth ladder (same pattern as
// /v1/admin/drain): no credentials => 401 from requireAuth; a valid consumer
// key that is not the admin key => 403 from isAdminAuthorized; the admin key
// => 200.
func TestAdminRejectModelsAuth(t *testing.T) {
	ts, _ := setupAdminRejectModels(t)

	if status, body := rejectModelsCall(t, ts, http.MethodGet, "", ""); status != http.StatusUnauthorized {
		t.Fatalf("no-auth GET status = %d, want 401; body = %s", status, body)
	}
	if status, body := rejectModelsCall(t, ts, http.MethodPut, "", `{"models":["x"]}`); status != http.StatusUnauthorized {
		t.Fatalf("no-auth PUT status = %d, want 401; body = %s", status, body)
	}
	if status, body := rejectModelsCall(t, ts, http.MethodGet, "test-key", ""); status != http.StatusForbidden {
		t.Fatalf("non-admin GET status = %d, want 403; body = %s", status, body)
	}
	if status, body := rejectModelsCall(t, ts, http.MethodPut, "test-key", `{"models":["x"]}`); status != http.StatusForbidden {
		t.Fatalf("non-admin PUT status = %d, want 403; body = %s", status, body)
	}
	status, body := rejectModelsCall(t, ts, http.MethodGet, "admin-secret", "")
	if status != http.StatusOK {
		t.Fatalf("admin GET status = %d, want 200; body = %s", status, body)
	}
	var got struct {
		Models []string `json:"models"`
	}
	if err := json.Unmarshal([]byte(body), &got); err != nil || got.Models == nil || len(got.Models) != 0 {
		t.Fatalf("admin GET body = %s, want {\"models\":[]} (never-nil array); err = %v", body, err)
	}
}

// TestAdminRejectModelsReplaceAndLiveFlip covers the full runtime flow: the
// startup-seeded set sheds requests on the real inference path, PUT replaces
// it live (no restart), GET reflects it, the previously shed model flows
// again, the newly shed one 429s, and an empty PUT sheds nothing.
func TestAdminRejectModelsReplaceAndLiveFlip(t *testing.T) {
	ts, srv := setupAdminRejectModels(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	seeded := "seeded-shed-model"
	runtime := "runtime-shed-model"
	// Startup env seeding path (cmd/coordinator/main.go calls SetRejectModels).
	srv.SetRejectModels(map[string]bool{seeded: true})

	// The seeded model is shed on the REAL inference path (429, model_shed).
	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, seeded)
	if err != nil {
		t.Fatalf("seeded request: %v", err)
	}
	if status != http.StatusTooManyRequests || !strings.Contains(body, "temporarily rate-limited") {
		t.Fatalf("seeded model status/body = %d %s, want shed 429", status, body)
	}
	if retryAfter == "" {
		t.Fatal("shed 429 missing Retry-After")
	}

	// PUT replaces the whole set at runtime.
	status, body = rejectModelsCall(t, ts, http.MethodPut, "admin-secret", `{"models":["`+runtime+`"," ",""]}`)
	if status != http.StatusOK {
		t.Fatalf("PUT status = %d, want 200; body = %s", status, body)
	}
	var put struct {
		Models   []string `json:"models"`
		Previous []string `json:"previous"`
	}
	if err := json.Unmarshal([]byte(body), &put); err != nil {
		t.Fatalf("PUT body = %s: %v", body, err)
	}
	if len(put.Models) != 1 || put.Models[0] != runtime || len(put.Previous) != 1 || put.Previous[0] != seeded {
		t.Fatalf("PUT response = %+v, want models=[%s] previous=[%s]", put, runtime, seeded)
	}

	// GET reflects the new set.
	if _, body = rejectModelsCall(t, ts, http.MethodGet, "admin-secret", ""); !strings.Contains(body, runtime) || strings.Contains(body, seeded) {
		t.Fatalf("GET after PUT = %s, want only %s", body, runtime)
	}

	// The flip is LIVE on the inference path: the seeded model is no longer
	// shed (it now falls through to the no-provider 503), the runtime one is.
	status, body, _, err = chatRequestWithHeaders(ctx, ts.URL, seeded)
	if err != nil {
		t.Fatalf("unshed request: %v", err)
	}
	if status != http.StatusServiceUnavailable || !strings.Contains(body, "model_unavailable") {
		t.Fatalf("unshed model status/body = %d %s, want no-provider 503 (shed lifted live)", status, body)
	}
	status, body, _, err = chatRequestWithHeaders(ctx, ts.URL, runtime)
	if err != nil {
		t.Fatalf("runtime-shed request: %v", err)
	}
	if status != http.StatusTooManyRequests || !strings.Contains(body, "temporarily rate-limited") {
		t.Fatalf("runtime-shed model status/body = %d %s, want shed 429", status, body)
	}

	// Empty list = shed nothing.
	if status, body = rejectModelsCall(t, ts, http.MethodPut, "admin-secret", `{"models":[]}`); status != http.StatusOK {
		t.Fatalf("clearing PUT status = %d, want 200; body = %s", status, body)
	}
	status, body, _, err = chatRequestWithHeaders(ctx, ts.URL, runtime)
	if err != nil {
		t.Fatalf("cleared request: %v", err)
	}
	if status != http.StatusServiceUnavailable {
		t.Fatalf("cleared model status = %d, want 503 (shed nothing); body = %s", status, body)
	}
}

// TestAdminRejectModelsWireShape pins the exact JSON keys of both responses so
// the typed response structs can never silently drift from the documented wire
// shape ({"models":[...]} for GET, {"models":[...],"previous":[...]} for PUT).
func TestAdminRejectModelsWireShape(t *testing.T) {
	ts, _ := setupAdminRejectModels(t)

	assertKeys := func(body string, want ...string) {
		t.Helper()
		var raw map[string]json.RawMessage
		if err := json.Unmarshal([]byte(body), &raw); err != nil {
			t.Fatalf("body %s: %v", body, err)
		}
		if len(raw) != len(want) {
			t.Fatalf("body %s has %d keys, want %v", body, len(raw), want)
		}
		for _, k := range want {
			if _, ok := raw[k]; !ok {
				t.Fatalf("body %s missing key %q, want keys %v", body, k, want)
			}
		}
	}

	status, body := rejectModelsCall(t, ts, http.MethodPut, "admin-secret", `{"models":["mlx-community/Qwen3.5-0.8B-MLX-4bit"]}`)
	if status != http.StatusOK {
		t.Fatalf("PUT status = %d, want 200; body = %s", status, body)
	}
	assertKeys(body, "models", "previous")

	status, body = rejectModelsCall(t, ts, http.MethodGet, "admin-secret", "")
	if status != http.StatusOK {
		t.Fatalf("GET status = %d, want 200; body = %s", status, body)
	}
	assertKeys(body, "models")
}

// TestAdminRejectModelsValidation drives the PUT input hardening through the
// real HTTP path: bounded count, bounded name length, no control characters,
// '/' explicitly legal (real model IDs contain it), and a rejected payload
// leaves the live set untouched.
func TestAdminRejectModelsValidation(t *testing.T) {
	longName := strings.Repeat("a", maxRejectModelNameLen+1)
	tooMany := make([]string, maxRejectModelsCount+1)
	for i := range tooMany {
		tooMany[i] = "m"
	}
	tooManyBody, _ := json.Marshal(map[string][]string{"models": tooMany})

	tests := []struct {
		name       string
		body       string
		wantStatus int
		wantSubstr string
	}{
		{"slash in model ID is legal", `{"models":["mlx-community/Qwen3.5-0.8B-MLX-4bit"]}`, http.StatusOK, "mlx-community/Qwen3.5-0.8B-MLX-4bit"},
		{"max-length name accepted", `{"models":["` + strings.Repeat("a", maxRejectModelNameLen) + `"]}`, http.StatusOK, ""},
		{"blank entries dropped, not errors", `{"models":["  ",""]}`, http.StatusOK, `"models":[]`},
		{"over-long name rejected", `{"models":["` + longName + `"]}`, http.StatusBadRequest, "exceeds"},
		{"NUL control character rejected", `{"models":["bad\u0000name"]}`, http.StatusBadRequest, "control character"},
		{"newline control character rejected", `{"models":["bad\nname"]}`, http.StatusBadRequest, "control character"},
		{"index reported for bad entry", `{"models":["ok","bad\tname"]}`, http.StatusBadRequest, "models[1]"},
		{"too many entries rejected", string(tooManyBody), http.StatusBadRequest, "too many models"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ts, srv := setupAdminRejectModels(t)
			sentinel := "pre-existing-model"
			srv.SetRejectModels(map[string]bool{sentinel: true})

			status, body := rejectModelsCall(t, ts, http.MethodPut, "admin-secret", tc.body)
			if status != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body = %s", status, tc.wantStatus, body)
			}
			if tc.wantSubstr != "" && !strings.Contains(body, tc.wantSubstr) {
				t.Fatalf("body = %s, want substring %q", body, tc.wantSubstr)
			}
			got := srv.RejectModels()
			if tc.wantStatus == http.StatusBadRequest {
				// A rejected payload must not half-apply: the live set is untouched.
				if len(got) != 1 || got[0] != sentinel {
					t.Fatalf("reject set after failed PUT = %v, want [%s] untouched", got, sentinel)
				}
			} else if len(got) != 0 && got[0] == sentinel {
				t.Fatalf("reject set after successful PUT still holds sentinel: %v", got)
			}
		})
	}
}

// TestAdminRejectModelsRequiresModelsKey is the finding-3 regression: clearing
// the shed list is an EXPLICIT operation ({"models":[]}), so a body with a
// missing, null, or typoed "models" key must be a 400 that leaves the live set
// untouched — never a silent clear that re-enables a model pulled from rotation
// during an incident.
func TestAdminRejectModelsRequiresModelsKey(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		wantStatus int
	}{
		{"empty object clears nothing (400)", `{}`, http.StatusBadRequest},
		{"null models clears nothing (400)", `{"models":null}`, http.StatusBadRequest},
		{"typoed key clears nothing (400)", `{"model":["x"]}`, http.StatusBadRequest},
		{"explicit empty list clears (200)", `{"models":[]}`, http.StatusOK},
		{"explicit list replaces (200)", `{"models":["replacement"]}`, http.StatusOK},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ts, srv := setupAdminRejectModels(t)
			sentinel := "incident-shed-model"
			srv.SetRejectModels(map[string]bool{sentinel: true})

			status, body := rejectModelsCall(t, ts, http.MethodPut, "admin-secret", tc.body)
			if status != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body = %s", status, tc.wantStatus, body)
			}
			got := srv.RejectModels()
			if tc.wantStatus == http.StatusBadRequest {
				if !strings.Contains(body, "models") {
					t.Fatalf("400 body = %s, want it to name the missing field", body)
				}
				// The set the operator installed during the incident must survive
				// the malformed request — a silent clear here is the footgun.
				if len(got) != 1 || got[0] != sentinel {
					t.Fatalf("reject set after 400 = %v, want [%s] untouched", got, sentinel)
				}
			} else if len(got) != 0 && got[0] == sentinel {
				t.Fatalf("reject set after successful PUT still holds sentinel: %v", got)
			}
		})
	}
}

// TestAdminRejectModelsFailsQueuedWaiters is the finding-4 regression: adding a
// model to the shed at runtime must fail its ALREADY-queued public waiters, not
// just future admission — otherwise up to a full queue window of requests keeps
// dispatching to a model the operator just pulled from rotation. Exclusive
// self-route waiters are preserved (they bypass the shed).
func TestAdminRejectModelsFailsQueuedWaiters(t *testing.T) {
	ts, srv := setupAdminRejectModels(t)
	queue := srv.registry.Queue()

	shedModel := "queued-shed-model"
	keepModel := "queued-keep-model"

	// A public waiter and a self-route waiter for the model about to be shed, plus
	// a public waiter for an unrelated model that must NOT be touched.
	publicShed := &registry.QueuedRequest{RequestID: "pub-shed", Model: shedModel, Pending: &registry.PendingRequest{RequestID: "pub-shed", Model: shedModel}}
	selfRouteShed := &registry.QueuedRequest{RequestID: "self-shed", Model: shedModel, Pending: &registry.PendingRequest{RequestID: "self-shed", Model: shedModel, SelfRouteOnly: true}}
	publicKeep := &registry.QueuedRequest{RequestID: "pub-keep", Model: keepModel, Pending: &registry.PendingRequest{RequestID: "pub-keep", Model: keepModel}}
	for _, q := range []*registry.QueuedRequest{publicShed, selfRouteShed, publicKeep} {
		if err := queue.Enqueue(q); err != nil {
			t.Fatalf("enqueue %s: %v", q.RequestID, err)
		}
	}

	// Shed only shedModel via the real admin HTTP path.
	status, body := rejectModelsCall(t, ts, http.MethodPut, "admin-secret", `{"models":["`+shedModel+`"]}`)
	if status != http.StatusOK {
		t.Fatalf("PUT status = %d, want 200; body = %s", status, body)
	}

	// The public waiter receives a typed shed failure, not a false queue timeout.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := queue.WaitForProviderContext(ctx, publicShed); !errors.Is(err, registry.ErrModelShed) {
		t.Fatalf("public shed waiter error = %v, want ErrModelShed", err)
	}

	// The self-route waiter for the shed model is preserved (bypasses the shed).
	select {
	case <-selfRouteShed.ResponseCh:
		t.Fatal("self-route waiter was failed on shed, want preserved")
	default:
	}

	// The waiter for an unrelated model is untouched.
	select {
	case <-publicKeep.ResponseCh:
		t.Fatal("unrelated-model waiter was failed on shed")
	default:
	}
}

// TestAdminRejectModelsFailsOnlyMatchingAliasWaiters pins queue identity across
// alias resolution. Requests queue under the concrete build id, but an operator
// may shed the caller-facing alias. Only requests made through that alias should
// fail; raw-build, other-alias, and exclusive self-route waiters sharing the
// concrete queue must survive.
func TestAdminRejectModelsFailsOnlyMatchingAliasWaiters(t *testing.T) {
	ts, srv := setupAdminRejectModels(t)
	queue := srv.registry.Queue()

	build := "mlx-community/model-build"
	alias := "public-model"
	otherAlias := "other-public-model"
	requests := []*registry.QueuedRequest{
		{RequestID: "alias", Model: build, Pending: &registry.PendingRequest{RequestID: "alias", Model: build, PublicModel: alias}},
		{RequestID: "raw", Model: build, Pending: &registry.PendingRequest{RequestID: "raw", Model: build, PublicModel: build}},
		{RequestID: "other-alias", Model: build, Pending: &registry.PendingRequest{RequestID: "other-alias", Model: build, PublicModel: otherAlias}},
		{RequestID: "self-alias", Model: build, Pending: &registry.PendingRequest{RequestID: "self-alias", Model: build, PublicModel: alias, SelfRouteOnly: true}},
	}
	for _, req := range requests {
		if err := queue.Enqueue(req); err != nil {
			t.Fatalf("enqueue %s: %v", req.RequestID, err)
		}
	}

	status, body := rejectModelsCall(t, ts, http.MethodPut, "admin-secret", `{"models":["`+alias+`"]}`)
	if status != http.StatusOK {
		t.Fatalf("PUT status = %d, want 200; body = %s", status, body)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := queue.WaitForProviderContext(ctx, requests[0]); !errors.Is(err, registry.ErrModelShed) {
		t.Fatalf("matching alias waiter error = %v, want ErrModelShed", err)
	}
	for _, req := range requests[1:] {
		select {
		case <-req.ResponseCh:
			t.Fatalf("nonmatching or self-route waiter %q was failed", req.RequestID)
		default:
		}
	}
	if got := queue.QueueSize(build); got != 3 {
		t.Fatalf("concrete build queue depth = %d, want 3 surviving waiters", got)
	}
}

// TestValidateRejectModelName covers the invalid-UTF-8 leg directly: it is
// unreachable through the HTTP path (encoding/json coerces invalid bytes to
// U+FFFD during decode) but guards non-JSON callers such as the
// EIGENINFERENCE_REJECT_MODELS startup seeding.
func TestValidateRejectModelName(t *testing.T) {
	if err := validateRejectModelName("mlx-community/Qwen3.5-0.8B-MLX-4bit"); err != nil {
		t.Fatalf("real model ID rejected: %v", err)
	}
	if err := validateRejectModelName("bad\xff\xfename"); err == nil {
		t.Fatal("invalid UTF-8 accepted, want error")
	}
	if err := validateRejectModelName("bad\x1bname"); err == nil {
		t.Fatal("ESC control character accepted, want error")
	}
}

// TestAdminRejectModelsConcurrentAccess exercises replace/read/shed-check under
// the race detector: the set is read on every inference admission while the
// admin endpoint replaces it.
func TestAdminRejectModelsConcurrentAccess(t *testing.T) {
	_, srv := setupAdminRejectModels(t)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				switch i % 3 {
				case 0:
					srv.ReplaceRejectModels(map[string]bool{"m-a": true, "m-b": j%2 == 0})
				case 1:
					_ = srv.RejectModels()
				default:
					_ = srv.modelShed("m-a", "m-b")
				}
			}
		}(i)
	}
	wg.Wait()

	// The queue guard and the public admission set must finish on the same
	// snapshot even when replacements race; otherwise a stale post-replace sweep
	// can reject the wrong model or admit a newly shed one.
	current := make(map[string]bool)
	for _, model := range srv.RejectModels() {
		current[model] = true
	}
	for _, model := range []string{"m-a", "m-b", "m-c"} {
		req := &registry.QueuedRequest{
			RequestID: "snapshot-" + model,
			Model:     model,
			Pending:   &registry.PendingRequest{RequestID: "snapshot-" + model, Model: model, PublicModel: model},
		}
		err := srv.registry.Queue().Enqueue(req)
		if gotShed := errors.Is(err, registry.ErrModelShed); gotShed != current[model] {
			t.Fatalf("queue shed snapshot for %q = %v (err %v), admission set = %v", model, gotShed, err, current)
		}
		if err == nil {
			srv.registry.Queue().Remove(req.RequestID, model)
		}
	}
}
