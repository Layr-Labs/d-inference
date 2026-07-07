package api

import (
	"context"
	"encoding/json"
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
}
