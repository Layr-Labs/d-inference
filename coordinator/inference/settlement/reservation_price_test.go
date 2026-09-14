package settlement

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The pre-flight reservation must NOT be topped up to a provider's higher custom
// price for service accounts (they settle at the platform price).
func TestServiceReservationNotToppedUpToProviderPrice(t *testing.T) {
	srv, st, ledger := settlementTestService(t)

	const model = "svc-reserve-model"
	const consumerID = "test-key"
	if err := st.CreateUser(&store.User{AccountID: consumerID, PrivyUserID: "did:privy:or2", Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}

	const provAcct = "svc-reserve-prov"
	if err := st.SetModelPrice(provAcct, model, 1_000_000, 50_000_000); err != nil { // very high
		t.Fatal(err)
	}
	provider := registry.New(srv.deps.Logger).Register("svc-reserve-prov-id", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = provAcct
	provider.Mu().Unlock()

	const base int64 = 100
	balBefore := ledger.Balance(consumerID)
	pr := &registry.PendingRequest{
		RequestID: "svc-reserve", Model: model, ConsumerKey: consumerID,
		ReservedMicroUSD: base, EstimatedPromptTokens: 1000, RequestedMaxTokens: 1000,
	}
	got, err := srv.ReserveForProvider(pr, provider)
	if err != nil {
		t.Fatal(err)
	}
	if got != base || pr.ReservedMicroUSD != base {
		t.Fatalf("service reservation topped up to %d (pr=%d), want unchanged base %d", got, pr.ReservedMicroUSD, base)
	}
	if ledger.Balance(consumerID) != balBefore {
		t.Errorf("service reservation charged extra: balance %d -> %d", balBefore, ledger.Balance(consumerID))
	}

	// Sanity: a normal consumer IS topped up to the provider price.
	_ = st.Credit("normie-key", 100_000_000, store.LedgerDeposit, "t")
	pr2 := &registry.PendingRequest{
		RequestID: "normal-reserve", Model: model, ConsumerKey: "normie-key",
		ReservedMicroUSD: base, EstimatedPromptTokens: 1000, RequestedMaxTokens: 1000,
	}
	got2, err := srv.ReserveForProvider(pr2, provider)
	if err != nil {
		t.Fatal(err)
	}
	if got2 <= base {
		t.Errorf("non-service reservation = %d, expected top-up above base %d", got2, base)
	}
}
