package inference

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// setOwnedProvider points every registered provider's AccountID at accountID,
// making that account the owner of the machine(s).
func setOwnedProvider(srv *Owner, accountID string) {
	for _, id := range srv.registry.ProviderIDs() {
		if p := srv.registry.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.AccountID = accountID
			p.Mu().Unlock()
		}
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
		ChunkCh:               make(chan registry.ProviderChunk, 1),
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
		ChunkCh:               make(chan registry.ProviderChunk, 1),
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
