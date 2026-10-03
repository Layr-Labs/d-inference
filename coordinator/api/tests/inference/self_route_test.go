package inference_test

// End-to-end HTTP tests for the "use my own machine, for free" (self-route)
// feature. They exercise the real handler path (auth → policy → routing →
// settlement) through httptest.NewServer, with a simulated provider over the
// WebSocket harness shared with the billing integration tests.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// sendSelfRouteRequest posts a chat completion. When selfHeader is set it adds
// X-Darkbloom-Route: self. Returns the HTTP status code.
func sendSelfRouteRequest(t *testing.T, ctx context.Context, tsURL, model, apiKey string, selfHeader bool) int {
	t.Helper()
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+apiKey)
	if selfHeader {
		req.Header.Set("X-Darkbloom-Route", "self")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)
	return resp.StatusCode
}

// TestSelfRoute_HeaderFreeHappyPath: a zero-balance account that OWNS the
// serving machine gets a successful, free inference via the header. Asserts no
// charge, no provider payout, and a zero-cost usage row.
func TestSelfRoute_HeaderFreeHappyPath(t *testing.T) {
	f, ledger := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "owner-acct"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "mine"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	// Deliberately do NOT credit the owner: a self-route request must succeed at
	// zero balance.
	if bal := ledger.Balance(owner); bal != 0 {
		t.Fatalf("precondition: owner balance = %d, want 0", bal)
	}

	model := "self-route-billing-model"
	conn, providerID, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner) // the machine belongs to the caller

	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	providerDone := testkit.ServeOneInference(ctx, t, conn, pubKey, usage)

	status := sendSelfRouteRequest(t, ctx, ts.URL, model, raw, true)
	if status != http.StatusOK {
		t.Fatalf("self-route status = %d, want 200", status)
	}
	<-providerDone
	time.Sleep(300 * time.Millisecond)

	// No charge to the owner.
	if bal := ledger.Balance(owner); bal != 0 {
		t.Errorf("owner balance = %d after free self-route, want 0", bal)
	}
	// A zero-cost usage row was still recorded for transparency.
	usageReq := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
	usageReq.Header.Set("Authorization", "Bearer "+raw)
	usageRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(usageRec, usageReq)
	if usageRec.Code != http.StatusOK {
		t.Fatalf("usage status = %d: %s", usageRec.Code, usageRec.Body.String())
	}
	var usageResponse types.UsageResponse
	if err := json.Unmarshal(usageRec.Body.Bytes(), &usageResponse); err != nil {
		t.Fatal(err)
	}
	usageEntries := usageResponse.Usage
	if len(usageEntries) != 1 {
		t.Fatalf("usage entries = %d, want 1", len(usageEntries))
	}
	if usageEntries[0].CostMicroUSD != 0 {
		t.Errorf("usage cost = %d, want 0 (free)", usageEntries[0].CostMicroUSD)
	}
	// No provider payout was accrued (consumer == provider account).
	earnings, _ := st.GetAccountEarnings(owner, 100)
	if len(earnings) != 0 {
		t.Errorf("provider earnings = %d, want 0 for free self-route", len(earnings))
	}
	_ = providerID
}

// TestSelfRoute_PerKeyFlagForcesFree: a key created with self_route_only=true
// self-routes (and is free) WITHOUT any header.
func TestSelfRoute_PerKeyFlagForcesFree(t *testing.T) {
	f, ledger := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "owner-acct-2"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "private", SelfRouteOnly: true})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	model := "self-route-perkey-model"
	conn, _, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)

	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20}
	providerDone := testkit.ServeOneInference(ctx, t, conn, pubKey, usage)

	// No header — the key flag alone must force the free self-route.
	status := sendSelfRouteRequest(t, ctx, ts.URL, model, raw, false)
	if status != http.StatusOK {
		t.Fatalf("per-key self-route status = %d, want 200", status)
	}
	<-providerDone
	time.Sleep(300 * time.Millisecond)

	if bal := ledger.Balance(owner); bal != 0 {
		t.Errorf("owner balance = %d, want 0 (per-key free)", bal)
	}
}

func TestSelfRouteOnlyKeyUsesOwnedOffCatalogModel(t *testing.T) {
	f, _ := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "owner-off-catalog"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "mine", SelfRouteOnly: true})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	model := "local/off-catalog-model"
	conn, _, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)
	f.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: "catalog-only-model"}})

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+raw)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("list models request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("list models status = %d body = %s", resp.StatusCode, body)
	}
	var listed types.ModelListResponse
	if err := json.NewDecoder(resp.Body).Decode(&listed); err != nil {
		t.Fatalf("decode list models: %v", err)
	}
	if len(listed.Data) != 1 || listed.Data[0].ID != model || listed.Data[0].OwnedBy != "self" {
		t.Fatalf("listed models = %+v, want one self-owned off-catalog model %q", listed.Data, model)
	}

	// Retrieve-model must agree with list: an OpenAI client that validates a
	// model id via GET /v1/models/{id} before use must find every listed model.
	getReq, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/models/"+model, nil)
	getReq.Header.Set("Authorization", "Bearer "+raw)
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("retrieve model request: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(getResp.Body)
		t.Fatalf("retrieve model status = %d body = %s", getResp.StatusCode, body)
	}
	var got types.ModelEntry
	if err := json.NewDecoder(getResp.Body).Decode(&got); err != nil {
		t.Fatalf("decode retrieve model: %v", err)
	}
	if got.ID != model || got.OwnedBy != "self" {
		t.Fatalf("retrieved model = %+v, want self-owned %q", got, model)
	}

	// Contrast: a PAID (non-self-route) key with balance must still get a 404
	// for the off-catalog model at the API layer — the catalog bypass is
	// exclusive-self-route only.
	if status := sendSelfRouteRequest(t, ctx, ts.URL, model, "test-key", false); status != http.StatusNotFound {
		t.Fatalf("paid key off-catalog status = %d, want 404", status)
	}

	providerDone := testkit.ServeOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5})
	if status := sendSelfRouteRequest(t, ctx, ts.URL, model, raw, false); status != http.StatusOK {
		t.Fatalf("self-route-only key status = %d, want 200", status)
	}
	<-providerDone
}

// TestSelfRoute_NormalRequestStillBilled is the contrast case: the SAME
// zero-balance account WITHOUT the self-route signal is gated by billing
// (402), proving that self-route is what bypasses billing — not some other
// path.
func TestSelfRoute_NormalRequestStillBilled(t *testing.T) {
	f, _ := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const owner = "owner-acct-3"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "mine"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	model := "self-route-contrast-model"
	conn, _, _ := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)

	// No header, zero balance → standard billing rejects with 402 before
	// dispatch (no provider serve needed).
	status := sendSelfRouteRequest(t, ctx, ts.URL, model, raw, false)
	if status != http.StatusPaymentRequired {
		t.Fatalf("normal zero-balance request status = %d, want 402", status)
	}
}

// TestSelfRoute_NoLinkedMachineReturns409: a caller who owns no machine gets a
// clean 409, and is NEVER routed to a provider owned by someone else (no
// fallback), even though that provider serves the model.
func TestSelfRoute_NoLinkedMachineReturns409(t *testing.T) {
	f, _ := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const caller = "owns-nothing"
	raw, _, err := st.CreateAPIKey(caller, store.APIKeyCreate{Name: "mine"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	model := "self-route-409-model"
	// Register a perfectly good provider, but owned by a DIFFERENT account so
	// the model is in catalog yet the caller owns nothing.
	conn, _, _ := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, "someone-else")

	status := sendSelfRouteRequest(t, ctx, ts.URL, model, raw, true)
	if status != http.StatusConflict {
		t.Fatalf("self-route with no linked machine status = %d, want 409", status)
	}
}

// sendRoutedRequest posts a chat completion with an explicit X-Darkbloom-Route
// value ("" = no header). Returns the HTTP status code.
func sendRoutedRequest(t *testing.T, ctx context.Context, tsURL, model, apiKey, route string) int {
	t.Helper()
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+apiKey)
	if route != "" {
		req.Header.Set("X-Darkbloom-Route", route)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)
	return resp.StatusCode
}

// TestSelfRoute_PreferFreeOnOwnedMachine: with X-Darkbloom-Route: prefer and a
// funded owner whose own machine serves the request, the up-front reservation is
// fully refunded (net free) and the provider accrues no payout. (prefer takes a
// reservation up front so a paid fallback could settle, unlike exclusive
// self-route which skips it — so the owner must have a balance.)
func TestSelfRoute_PreferFreeOnOwnedMachine(t *testing.T) {
	f, ledger := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "prefer-owner"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "mine"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	_ = st.Credit(owner, 100_000_000, store.LedgerDeposit, "test-setup")
	initial := ledger.Balance(owner)

	model := "prefer-owned-model"
	conn, _, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)

	providerDone := testkit.ServeOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50})
	if status := sendRoutedRequest(t, ctx, ts.URL, model, raw, "prefer"); status != http.StatusOK {
		t.Fatalf("prefer status = %d, want 200", status)
	}
	<-providerDone
	time.Sleep(300 * time.Millisecond)

	if bal := ledger.Balance(owner); bal != initial {
		t.Errorf("owner balance = %d, want %d (prefer served by own machine must be net free)", bal, initial)
	}
	earnings, _ := st.GetAccountEarnings(owner, 100)
	if len(earnings) != 0 {
		t.Errorf("provider earnings = %d, want 0 when own machine served a prefer request", len(earnings))
	}
}

// TestSelfRoute_PreferFallsBackToPaid: with prefer and an owner who owns NO
// machine, the request falls back to the paid public fleet and is charged —
// unlike exclusive self-route, which would 409. "Never a dead end."
func TestSelfRoute_PreferFallsBackToPaid(t *testing.T) {
	f, ledger := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const caller = "prefer-owns-nothing"
	raw, _, err := st.CreateAPIKey(caller, store.APIKeyCreate{Name: "mine"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	_ = st.Credit(caller, 100_000_000, store.LedgerDeposit, "test-setup")
	initial := ledger.Balance(caller)

	model := "prefer-fallback-paid-model"
	conn, _, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, "someone-else") // caller owns nothing

	providerDone := testkit.ServeOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50})
	if status := sendRoutedRequest(t, ctx, ts.URL, model, raw, "prefer"); status != http.StatusOK {
		t.Fatalf("prefer fallback status = %d, want 200 (must fall back to paid, not 409)", status)
	}
	<-providerDone
	time.Sleep(300 * time.Millisecond)

	if bal := ledger.Balance(caller); bal >= initial {
		t.Errorf("caller balance = %d, want < %d (paid fallback must charge)", bal, initial)
	}
}
