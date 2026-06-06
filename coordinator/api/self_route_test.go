package api

// End-to-end HTTP tests for the "use my own machine, for free" (self-route)
// feature. They exercise the real handler path (auth → policy → routing →
// settlement) through httptest.NewServer, with a simulated provider over the
// WebSocket harness shared with the billing integration tests.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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

// setOwnedProvider points every registered provider's AccountID at accountID,
// making that account the owner of the machine(s).
func setOwnedProvider(srv *Server, accountID string) {
	for _, id := range srv.registry.ProviderIDs() {
		if p := srv.registry.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.AccountID = accountID
			p.Mu().Unlock()
		}
	}
}

// TestSelfRoute_HeaderFreeHappyPath: a zero-balance account that OWNS the
// serving machine gets a successful, free inference via the header. Asserts no
// charge, no provider payout, and a zero-cost usage row.
func TestSelfRoute_HeaderFreeHappyPath(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
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
	conn, providerID, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner) // the machine belongs to the caller

	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

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
	usageEntries := ledger.Usage(owner)
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
	srv, st, ledger := billingTestServer(t)
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
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner)

	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

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

// TestSelfRoute_NormalRequestStillBilled is the contrast case: the SAME
// zero-balance account WITHOUT the self-route signal is gated by billing
// (402), proving that self-route is what bypasses billing — not some other
// path.
func TestSelfRoute_NormalRequestStillBilled(t *testing.T) {
	srv, st, _ := billingTestServer(t)
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
	conn, _, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner)

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
	srv, st, _ := billingTestServer(t)
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
	conn, _, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, "someone-else")

	status := sendSelfRouteRequest(t, ctx, ts.URL, model, raw, true)
	if status != http.StatusConflict {
		t.Fatalf("self-route with no linked machine status = %d, want 409", status)
	}
}

// TestSelfRoute_SettlementMismatchFallsBackToPaid is the defense-in-depth
// regression: if a request marked FreeSelfRoute is somehow completed by a
// provider the consumer does NOT own (e.g. the machine was unlinked/relinked
// mid-flight), settlement must fall back to PAID rather than grant free
// inference on a stranger's machine. The router never produces this state, so
// we construct it directly: reserve on an owned machine, then flip ownership
// before completion.
func TestSelfRoute_SettlementMismatchFallsBackToPaid(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const owner = "owner-mismatch"
	_ = st.Credit(owner, 100_000_000, store.LedgerDeposit, "test-setup") // fund for the paid fallback
	initialBalance := ledger.Balance(owner)

	model := "self-route-mismatch-model"
	conn, providerID, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner)

	// Reserve a self-route request on the owned machine (router-equivalent).
	pr := &registry.PendingRequest{
		RequestID:             "mismatch-req",
		Model:                 model,
		ConsumerKey:           owner,
		OwnerAccountID:        owner,
		SelfRouteOnly:         true,
		FreeSelfRoute:         true,
		EstimatedPromptTokens: 50,
		RequestedMaxTokens:    128,
		AcceptedCh:            make(chan struct{}, 1),
		ChunkCh:               make(chan string, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}
	selected, _ := srv.registry.ReserveProviderEx(model, pr)
	if selected == nil {
		t.Fatal("failed to reserve the owned provider for the self-route request")
	}

	// Simulate the machine being unlinked / relinked to a different account
	// after dispatch but before completion.
	if p := srv.registry.GetProvider(providerID); p != nil {
		p.Mu().Lock()
		p.AccountID = "a-stranger"
		p.Mu().Unlock()
	}

	srv.handleComplete(providerID, selected, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50},
	})

	// The owner must have been CHARGED (paid fallback), not given free inference.
	finalBalance := ledger.Balance(owner)
	if finalBalance >= initialBalance {
		t.Fatalf("owner balance %d not reduced from %d — mismatch must settle as paid, not free", finalBalance, initialBalance)
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
	srv, st, ledger := billingTestServer(t)
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
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner)

	providerDone := serveOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50})
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
	srv, st, ledger := billingTestServer(t)
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
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, "someone-else") // caller owns nothing

	providerDone := serveOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50})
	if status := sendRoutedRequest(t, ctx, ts.URL, model, raw, "prefer"); status != http.StatusOK {
		t.Fatalf("prefer fallback status = %d, want 200 (must fall back to paid, not 409)", status)
	}
	<-providerDone
	time.Sleep(300 * time.Millisecond)

	if bal := ledger.Balance(caller); bal >= initial {
		t.Errorf("caller balance = %d, want < %d (paid fallback must charge)", bal, initial)
	}
}

// TestSelfRoute_UnfundedFallbackDoesNotPayProvider is the Part 3 regression: a
// FreeSelfRoute request whose ownership revalidation fails at settlement AND
// whose owner has NO balance must not record paid usage or credit the provider
// from an unfunded balance.
func TestSelfRoute_UnfundedFallbackDoesNotPayProvider(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const owner = "unfunded-owner"
	if bal := ledger.Balance(owner); bal != 0 {
		t.Fatalf("precondition: balance = %d, want 0", bal)
	}

	model := "unfunded-mismatch-model"
	conn, providerID, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner)

	pr := &registry.PendingRequest{
		RequestID:             "unfunded-req",
		Model:                 model,
		ConsumerKey:           owner,
		OwnerAccountID:        owner,
		SelfRouteOnly:         true,
		FreeSelfRoute:         true,
		EstimatedPromptTokens: 50,
		RequestedMaxTokens:    128,
		AcceptedCh:            make(chan struct{}, 1),
		ChunkCh:               make(chan string, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}
	selected, _ := srv.registry.ReserveProviderEx(model, pr)
	if selected == nil {
		t.Fatal("failed to reserve the owned provider")
	}
	// Unlink the machine to a stranger before completion → ownership revalidation
	// fails → paid fallback → charge fails (owner unfunded).
	if p := srv.registry.GetProvider(providerID); p != nil {
		p.Mu().Lock()
		p.AccountID = "a-stranger"
		p.Mu().Unlock()
	}
	srv.handleComplete(providerID, selected, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50},
	})

	// The (stranger) provider must NOT be credited from an unfunded balance.
	earnings, _ := st.GetAccountEarnings("a-stranger", 100)
	if len(earnings) != 0 {
		t.Errorf("provider earnings = %d, want 0 (no payout from an unfunded balance)", len(earnings))
	}
}
