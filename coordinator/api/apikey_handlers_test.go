package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newKeyTestServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	return srv, st
}

// reqWithUser builds a request whose context carries an authenticated user,
// simulating what requirePrivyAuth installs (so we can unit-test the handlers
// without minting a real Privy JWT).
func reqWithUser(method, target, body, accountID string) *http.Request {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, target, nil)
	} else {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
	}
	ctx := context.WithValue(r.Context(), auth.CtxKeyUser, &store.User{AccountID: accountID})
	ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
	return r.WithContext(ctx)
}

func TestHandleCreateAndListAPIKeys(t *testing.T) {
	srv, _ := newKeyTestServer(t)

	// Create a key with a $10 monthly cap.
	body := `{"name":"prod","limit_usd":10,"limit_reset":"monthly","rpm_limit":120}`
	w := httptest.NewRecorder()
	srv.handleCreateAPIKey(w, reqWithUser(http.MethodPost, "/v1/keys", body, "acct-1"))
	if w.Code != http.StatusOK {
		t.Fatalf("create status = %d, body=%s", w.Code, w.Body.String())
	}
	var created types.CreateAPIKeyResponse
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create: %v", err)
	}
	if !strings.HasPrefix(created.Key, store.KeyPrefix) {
		t.Errorf("returned secret %q missing prefix", created.Key)
	}
	if created.Data.LimitUSD == nil || *created.Data.LimitUSD != 10 {
		t.Errorf("limit_usd = %v, want 10", created.Data.LimitUSD)
	}
	if created.Data.LimitReset != "monthly" {
		t.Errorf("limit_reset = %q", created.Data.LimitReset)
	}
	if created.Data.RPMLimit == nil || *created.Data.RPMLimit != 120 {
		t.Errorf("rpm_limit = %v", created.Data.RPMLimit)
	}
	if strings.Contains(created.Data.Label, created.Key[10:40]) {
		t.Errorf("label leaks secret: %q", created.Data.Label)
	}

	// List shows exactly one key (masked, no secret).
	w = httptest.NewRecorder()
	srv.handleListAPIKeys(w, reqWithUser(http.MethodGet, "/v1/keys", "", "acct-1"))
	if w.Code != http.StatusOK {
		t.Fatalf("list status = %d", w.Code)
	}
	var list types.APIKeyListResponse
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list.Data) != 1 {
		t.Fatalf("list len = %d, want 1", len(list.Data))
	}
	if strings.Contains(w.Body.String(), created.Key) {
		t.Error("list response must not contain the raw secret")
	}
}

func TestHandleUpdateAndDisableViaPatch(t *testing.T) {
	srv, _ := newKeyTestServer(t)

	w := httptest.NewRecorder()
	srv.handleCreateAPIKey(w, reqWithUser(http.MethodPost, "/v1/keys", `{"name":"a","limit_usd":5}`, "acct-1"))
	var created types.CreateAPIKeyResponse
	json.Unmarshal(w.Body.Bytes(), &created)
	id := created.Data.ID

	// PATCH: disable + clear the limit (limit_usd: null) + rename.
	patch := `{"name":"renamed","disabled":true,"limit_usd":null}`
	r := reqWithUser(http.MethodPatch, "/v1/keys/"+id, patch, "acct-1")
	r.SetPathValue("id", id)
	w = httptest.NewRecorder()
	srv.handleUpdateAPIKey(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("patch status = %d, body=%s", w.Code, w.Body.String())
	}
	var updated types.APIKeyResponse
	json.Unmarshal(w.Body.Bytes(), &updated)
	if updated.Name != "renamed" {
		t.Errorf("name = %q", updated.Name)
	}
	if !updated.Disabled {
		t.Error("key should be disabled")
	}
	if updated.LimitUSD != nil {
		t.Errorf("limit_usd should be cleared, got %v", *updated.LimitUSD)
	}
}

func TestHandleRotateAPIKey(t *testing.T) {
	srv, _ := newKeyTestServer(t)

	w := httptest.NewRecorder()
	srv.handleCreateAPIKey(w, reqWithUser(http.MethodPost, "/v1/keys", `{"name":"a","limit_usd":7,"limit_reset":"weekly"}`, "acct-1"))
	var created types.CreateAPIKeyResponse
	json.Unmarshal(w.Body.Bytes(), &created)
	oldID := created.Data.ID
	oldSecret := created.Key

	r := reqWithUser(http.MethodPost, "/v1/keys/"+oldID+"/rotate", "", "acct-1")
	r.SetPathValue("id", oldID)
	w = httptest.NewRecorder()
	srv.handleRotateAPIKey(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("rotate status = %d, body=%s", w.Code, w.Body.String())
	}
	var rotated types.CreateAPIKeyResponse
	json.Unmarshal(w.Body.Bytes(), &rotated)
	if rotated.Key == oldSecret {
		t.Error("rotate must mint a new secret")
	}
	if rotated.Data.ID == oldID {
		t.Error("rotate must produce a new key id")
	}
	// Limits carried over.
	if rotated.Data.LimitUSD == nil || *rotated.Data.LimitUSD != 7 || rotated.Data.LimitReset != "weekly" {
		t.Errorf("limits not carried over: %+v", rotated.Data)
	}
	// Old key gone.
	if _, err := srv.store.AuthenticateKey(oldSecret); err == nil {
		t.Error("old secret should be revoked after rotate")
	}
	// New key authenticates.
	if _, err := srv.store.AuthenticateKey(rotated.Key); err != nil {
		t.Errorf("new secret should authenticate: %v", err)
	}
}

func TestHandleDeleteAPIKeyScoping(t *testing.T) {
	srv, _ := newKeyTestServer(t)

	w := httptest.NewRecorder()
	srv.handleCreateAPIKey(w, reqWithUser(http.MethodPost, "/v1/keys", `{"name":"a"}`, "acct-1"))
	var created types.CreateAPIKeyResponse
	json.Unmarshal(w.Body.Bytes(), &created)
	id := created.Data.ID

	// Another account cannot delete it.
	r := reqWithUser(http.MethodDelete, "/v1/keys/"+id, "", "acct-2")
	r.SetPathValue("id", id)
	w = httptest.NewRecorder()
	srv.handleDeleteAPIKey(w, r)
	if w.Code != http.StatusNotFound {
		t.Fatalf("cross-account delete status = %d, want 404", w.Code)
	}

	// Owner can.
	r = reqWithUser(http.MethodDelete, "/v1/keys/"+id, "", "acct-1")
	r.SetPathValue("id", id)
	w = httptest.NewRecorder()
	srv.handleDeleteAPIKey(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("owner delete status = %d, want 200", w.Code)
	}
}

func TestHandleCreateAPIKeyRejectsBadInput(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	w := httptest.NewRecorder()
	srv.handleCreateAPIKey(w, reqWithUser(http.MethodPost, "/v1/keys", `{"limit_reset":"hourly"}`, "acct-1"))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 for bad reset window", w.Code)
	}
}
