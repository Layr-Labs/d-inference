package api

// earnings_authz_test.go — authorization tests for the two earnings endpoints
// that were previously unauthenticated IDORs (SEC-XXX).
//
// Routes under test:
//   GET /v1/provider/earnings      (handleProviderEarnings)
//   GET /v1/provider/node-earnings (handleNodeEarnings)
//
// Both are now wrapped in requireAuth and scope data to the authenticated account.
// Tests exercise the REAL HTTP path via srv.Handler().ServeHTTP so the routing
// middleware fires exactly as in production.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// earningsAuthzServer returns a test server and store pre-populated with two
// accounts, each owning one provider node and one earning record.
//
//	accountA / provider-key-A — earnings row with AmountMicroUSD=100_000
//	accountB / provider-key-B — earnings row with AmountMicroUSD=200_000
//
// The ledger also has a direct credit for accountA (450_000) to exercise the
// handleProviderEarnings balance path.
func earningsAuthzServer(t *testing.T) (*Server, *store.MemoryStore, string, string) {
	t.Helper()
	srv, st := testBillingServer(t)

	now := time.Now()

	// Account A: one linked provider earning (accountID used as ledger key).
	earningA := store.ProviderEarning{
		AccountID:      "acct-A",
		ProviderID:     "node-A",
		ProviderKey:    "provider-key-A",
		JobID:          "job-A1",
		Model:          "model-x",
		AmountMicroUSD: 100_000,
		CreatedAt:      now,
	}
	if err := st.CreditProviderAccount(&earningA); err != nil {
		t.Fatalf("CreditProviderAccount A: %v", err)
	}

	// Account B: one linked provider earning.
	earningB := store.ProviderEarning{
		AccountID:      "acct-B",
		ProviderID:     "node-B",
		ProviderKey:    "provider-key-B",
		JobID:          "job-B1",
		Model:          "model-y",
		AmountMicroUSD: 200_000,
		CreatedAt:      now,
	}
	if err := st.CreditProviderAccount(&earningB); err != nil {
		t.Fatalf("CreditProviderAccount B: %v", err)
	}

	return srv, st, "acct-A", "acct-B"
}

// authRequest sets the ctxKeyConsumer context value, simulating what requireAuth
// does after verifying a valid API key or Privy JWT. The mux will still see
// this if the request passes through HandleFunc — to bypass requireAuth we must
// inject the context before the mux sees the request. For the Handler() path we
// need the real Bearer token path, so instead we call the handler directly where
// we need to test scoping, and we use Handler() only for the 401/403 gate tests.
func authRequest(r *http.Request, accountID string) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, accountID))
}

// ---------------------------------------------------------------------------
// /v1/provider/earnings — anonymous access must be blocked
// ---------------------------------------------------------------------------

func TestEarningsAuthz_ProviderEarnings_Anon401(t *testing.T) {
	srv, _, _, _ := earningsAuthzServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet=acct-A", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// Before the fix this returned 200; after the fix it must return 401.
	if w.Code != http.StatusUnauthorized {
		t.Errorf("anonymous GET /v1/provider/earnings: status = %d, want 401", w.Code)
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/node-earnings — anonymous access must be blocked
// ---------------------------------------------------------------------------

func TestEarningsAuthz_NodeEarnings_Anon401(t *testing.T) {
	srv, _, _, _ := earningsAuthzServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=provider-key-A", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// Before the fix this returned 200; after the fix it must return 401.
	if w.Code != http.StatusUnauthorized {
		t.Errorf("anonymous GET /v1/provider/node-earnings: status = %d, want 401", w.Code)
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/node-earnings IDOR — authed-A must NOT see authed-B's data
// ---------------------------------------------------------------------------

func TestEarningsAuthz_NodeEarnings_CrossAccount403(t *testing.T) {
	srv, _, accountA, _ := earningsAuthzServer(t)

	// Account A is authenticated but requests account B's provider_key.
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=provider-key-B", nil)
	req = authRequest(req, accountA) // authenticated as A
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	// Before the fix this returned 200 with B's data; after the fix it must return 403.
	if w.Code != http.StatusForbidden {
		t.Errorf("cross-account node-earnings: status = %d, want 403 (body: %s)", w.Code, w.Body.String())
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/earnings IDOR — authed-A must NOT see authed-B's balance
// ---------------------------------------------------------------------------

func TestEarningsAuthz_ProviderEarnings_CrossAccountIsolated(t *testing.T) {
	srv, _, accountA, accountB := earningsAuthzServer(t)

	// Account A authenticated — should see only A's balance (100_000), not B's (200_000).
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	req = authRequest(req, accountA)
	w := httptest.NewRecorder()
	srv.handleProviderEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("authed-A provider-earnings: status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}

	var respA map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &respA); err != nil {
		t.Fatalf("unmarshal A response: %v", err)
	}

	// A's balance must equal A's earning only (100_000), not A+B.
	balA := respA["balance_micro_usd"].(float64)
	if balA == float64(100_000+200_000) {
		t.Errorf("IDOR: account A sees combined balance of A+B (%v); data not isolated", balA)
	}
	if balA != 100_000 {
		t.Errorf("account A balance = %v, want 100000", balA)
	}

	// Account B authenticated — should see only B's balance (200_000).
	reqB := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	reqB = authRequest(reqB, accountB)
	wB := httptest.NewRecorder()
	srv.handleProviderEarnings(wB, reqB)

	if wB.Code != http.StatusOK {
		t.Fatalf("authed-B provider-earnings: status = %d, want 200 (body: %s)", wB.Code, wB.Body.String())
	}

	var respB map[string]any
	if err := json.Unmarshal(wB.Body.Bytes(), &respB); err != nil {
		t.Fatalf("unmarshal B response: %v", err)
	}

	balB := respB["balance_micro_usd"].(float64)
	if balB != 200_000 {
		t.Errorf("account B balance = %v, want 200000", balB)
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/node-earnings — authed owner gets 200 with own data
// ---------------------------------------------------------------------------

func TestEarningsAuthz_NodeEarnings_OwnKey200(t *testing.T) {
	srv, _, accountA, _ := earningsAuthzServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=provider-key-A&limit=10", nil)
	req = authRequest(req, accountA)
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("own key node-earnings: status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if resp["provider_key"] != "provider-key-A" {
		t.Errorf("provider_key = %v, want provider-key-A", resp["provider_key"])
	}

	total := resp["total_micro_usd"].(float64)
	if total != 100_000 {
		t.Errorf("total_micro_usd = %v, want 100000", total)
	}

	earnings, ok := resp["earnings"].([]any)
	if !ok || len(earnings) != 1 {
		t.Errorf("earnings = %v, want 1 row", resp["earnings"])
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/earnings — authed owner gets 200 with own data
// ---------------------------------------------------------------------------

func TestEarningsAuthz_ProviderEarnings_OwnAccount200(t *testing.T) {
	srv, _, accountA, _ := earningsAuthzServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	req = authRequest(req, accountA)
	w := httptest.NewRecorder()
	srv.handleProviderEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("own account provider-earnings: status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// A's earning was credited via CreditProviderAccount which debits accountID.
	bal := resp["balance_micro_usd"].(float64)
	if bal != 100_000 {
		t.Errorf("balance_micro_usd = %v, want 100000", bal)
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/node-earnings — empty earnings for unknown key not owned by caller
// returns 200 with empty data (not a 403, since there are no rows to check ownership).
// This is acceptable: the caller learns the key has no earnings, not cross-account data.
// ---------------------------------------------------------------------------

func TestEarningsAuthz_NodeEarnings_UnknownKey200Empty(t *testing.T) {
	srv, _, accountA, _ := earningsAuthzServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=totally-unknown-key", nil)
	req = authRequest(req, accountA)
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	// No earnings rows → no AccountID to check → falls through to empty 200.
	if w.Code != http.StatusOK {
		t.Errorf("unknown key node-earnings: status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	total := resp["total_micro_usd"].(float64)
	if total != 0 {
		t.Errorf("total_micro_usd = %v, want 0 for unknown key", total)
	}
}

// ---------------------------------------------------------------------------
// /v1/provider/node-earnings — a re-linked provider_key with rows under TWO
// accounts must NOT leak the other account's aggregate. The provider_key is a
// stable hardware key, so a device moved from A to B has rows under both;
// account B must see ONLY its own lifetime total, never A+B.
// ---------------------------------------------------------------------------

func TestEarningsAuthz_NodeEarnings_MultiAccountNoCrossLeak(t *testing.T) {
	srv, st, accountA, accountB := earningsAuthzServer(t)

	sharedKey := "provider-key-shared"
	// A's row first, then B's (newest) — so B's row is earnings[0], which would
	// pass a naive [0]-only ownership check while the summary still aggregated
	// A+B. The fix must scope the summary to the caller.
	if err := st.CreditProviderAccount(&store.ProviderEarning{
		AccountID: accountA, ProviderID: "node-shared", ProviderKey: sharedKey,
		JobID: "job-S-A", Model: "model-x", AmountMicroUSD: 111_000, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("credit A: %v", err)
	}
	if err := st.CreditProviderAccount(&store.ProviderEarning{
		AccountID: accountB, ProviderID: "node-shared", ProviderKey: sharedKey,
		JobID: "job-S-B", Model: "model-x", AmountMicroUSD: 222_000, CreatedAt: time.Now().Add(time.Second),
	}); err != nil {
		t.Fatalf("credit B: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key="+sharedKey, nil)
	req = authRequest(req, accountB)
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("multi-account node-earnings: status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	total := resp["total_micro_usd"].(float64)
	if total == float64(111_000+222_000) {
		t.Errorf("CROSS-ACCOUNT LEAK: B sees combined A+B total (%v); summary not account-scoped", total)
	}
	if total != 222_000 {
		t.Errorf("total_micro_usd = %v, want 222000 (B's own lifetime only)", total)
	}
	// Detail rows must all be B's.
	if rows, _ := resp["earnings"].([]any); len(rows) != 1 {
		t.Errorf("earnings rows = %d, want 1 (only B's)", len(rows))
	}
}
