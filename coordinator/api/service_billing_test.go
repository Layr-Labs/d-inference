package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Service-role (OpenRouter) traffic must be billed at the advertised platform
// price (never a provider's higher custom price) and exempt from the per-request
// minimum charge — so the debit matches the published per-token feed.
func TestServiceAccountBilledAtPlatformPriceNoMinimum(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	const model = "service-billing-model"
	consumerID := testConsumerID // seeded with $100 by the harness

	// Mark the consumer as a service (OpenRouter) account.
	if err := st.CreateUser(&store.User{AccountID: consumerID, PrivyUserID: "did:privy:or", Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}

	// Advertised platform price + a much higher provider custom price.
	const platformIn, platformOut int64 = 50_000, 200_000
	const provIn, provOut int64 = 50_000, 10_000_000
	if err := st.SetModelPrice("platform", model, platformIn, platformOut); err != nil {
		t.Fatal(err)
	}
	const provAcct = "svc-prov-acct"
	if err := st.SetModelPrice(provAcct, model, provIn, provOut); err != nil {
		t.Fatal(err)
	}

	provider := srv.registry.Register("svc-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = provAcct
	provider.Mu().Unlock()

	// Tiny request: the platform per-token cost is below the per-request minimum,
	// and far below the provider-priced cost — so the assertion distinguishes
	// platform-no-min from both provider pricing and the minimum floor.
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 10}
	expected := payments.CalculateCostWithOverridesNoMinimum(model, usage.PromptTokens, usage.CompletionTokens, platformIn, platformOut, true)
	if expected >= payments.MinimumCharge() {
		t.Fatalf("test setup: platform cost %d should be below the minimum %d", expected, payments.MinimumCharge())
	}

	initial := ledger.Balance(consumerID)
	const reserve int64 = 1_000_000
	if err := ledger.Charge(consumerID, reserve, "reserve:"+consumerID); err != nil {
		t.Fatal(err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "svc-billing",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	// Net charge must equal the platform no-minimum cost — not the provider's
	// higher custom price, and not floored to the minimum.
	if got := ledger.Balance(consumerID); got != initial-expected {
		t.Fatalf("consumer balance = %d, want %d (platform no-min cost %d). A higher value means provider pricing or the minimum floor leaked in.",
			got, initial-expected, expected)
	}
}

// The pre-flight reservation must NOT be topped up to a provider's higher custom
// price for service accounts (they settle at the platform price).
func TestServiceReservationNotToppedUpToProviderPrice(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	const model = "svc-reserve-model"
	const consumerID = "test-key"
	if err := st.CreateUser(&store.User{AccountID: consumerID, PrivyUserID: "did:privy:or2", Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}

	const provAcct = "svc-reserve-prov"
	if err := st.SetModelPrice(provAcct, model, 1_000_000, 50_000_000); err != nil { // very high
		t.Fatal(err)
	}
	provider := srv.registry.Register("svc-reserve-prov-id", nil, &protocol.RegisterMessage{
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
	got, err := srv.reserveAdditionalForProvider(pr, provider)
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
	got2, err := srv.reserveAdditionalForProvider(pr2, provider)
	if err != nil {
		t.Fatal(err)
	}
	if got2 <= base {
		t.Errorf("non-service reservation = %d, expected top-up above base %d", got2, base)
	}
}
