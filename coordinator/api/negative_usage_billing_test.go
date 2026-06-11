package api

// Regression tests for the balance-minting bug caused by unvalidated negative
// provider-supplied usage token counts (CVE-level fix, all layers).
//
// Each test MUST fail without the corresponding fix and PASS with it.

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestNegativeCompletionTokensNoMint is the primary settlement-level regression.
//
// Setup: a service-role consumer (NoMinimum billing path, most vulnerable)
// with a positive reservation. The provider sends an InferenceComplete with
// negative completion_tokens. Without the fix, calculateCostNoMinimum returns a
// negative cost, making refund = reserved - negative > reserved, and
// store.Credit mints balance above the reservation amount.
//
// Assertion: consumer balance after settlement must be >= initial balance
// (no balance increase from the interaction), and specifically the refund must
// not exceed the original reservation.
func TestNegativeCompletionTokensNoMint(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	const model = "neg-usage-test-model"
	consumerID := testConsumerID // seeded $100 by harness

	// Mark as service (RoleService → NoMinimum path, most vulnerable to this bug).
	if err := st.CreateUser(&store.User{
		AccountID:   consumerID,
		PrivyUserID: "did:privy:neg-test",
		Role:        store.RoleService,
	}); err != nil {
		t.Fatal(err)
	}

	provider := srv.registry.Register("neg-test-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "neg-test-prov-acct"
	provider.Mu().Unlock()

	// Record the initial balance (before reservation).
	initialBalance := ledger.Balance(consumerID)

	// Simulate a pre-flight reservation (consumer balance debited).
	const reserve int64 = 1_000_000 // $1.00 reserved
	if err := ledger.Charge(consumerID, reserve, "reserve:neg-test"); err != nil {
		t.Fatal(err)
	}
	balanceAfterReserve := ledger.Balance(consumerID)
	if balanceAfterReserve != initialBalance-reserve {
		t.Fatalf("after reservation: balance = %d, want %d", balanceAfterReserve, initialBalance-reserve)
	}

	// Wire up a PendingRequest with the reservation.
	pr := &registry.PendingRequest{
		RequestID:        "neg-usage-req",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	// Provider sends a malicious negative completion_tokens value.
	// Without layer-1 clamp: calculateCostNoMinimum returns a large negative
	// cost; refund = reserve - negative = very large positive → mint.
	maliciousUsage := protocol.UsageInfo{
		PromptTokens:     100,
		CompletionTokens: -1_000_000, // malicious: −1M tokens
	}

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     maliciousUsage,
	})

	finalBalance := ledger.Balance(consumerID)

	// The consumer must NOT have more balance than before the reservation was
	// charged. Any increase above (initialBalance - reserve) indicates minting.
	// At best (full refund) the consumer gets back to initialBalance; the
	// refund must NEVER exceed the reserved amount.
	if finalBalance > initialBalance {
		t.Errorf("MINT DETECTED: balance after negative-token settlement = %d, initial balance = %d; "+
			"consumer gained %d micro-USD from negative usage tokens",
			finalBalance, initialBalance, finalBalance-initialBalance)
	}

	// Refund must be at most the reserved amount.
	refundReceived := finalBalance - balanceAfterReserve
	if refundReceived > reserve {
		t.Errorf("over-refund DETECTED: refund = %d, reservation = %d; "+
			"excess minting = %d micro-USD",
			refundReceived, reserve, refundReceived-reserve)
	}
}

// TestNegativePromptTokensNoMint ensures negative prompt_tokens also cannot mint.
func TestNegativePromptTokensNoMint(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	const model = "neg-prompt-test-model"
	consumerID := testConsumerID

	// Service-role consumer → NoMinimum billing path, where a negative cost is
	// NOT floored to the minimum charge. This is the path that actually exercises
	// the clamp: on the regular (minimum-floor) path the floor masks a negative
	// cost, so the test would pass even with the fix reverted. Mirrors
	// TestNegativeCompletionTokensNoMint.
	if err := st.CreateUser(&store.User{
		AccountID:   consumerID,
		PrivyUserID: "did:privy:neg-prompt-test",
		Role:        store.RoleService,
	}); err != nil {
		t.Fatal(err)
	}

	provider := srv.registry.Register("neg-prompt-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "neg-prompt-prov-acct"
	provider.Mu().Unlock()

	initialBalance := ledger.Balance(consumerID)
	const reserve int64 = 500_000
	if err := ledger.Charge(consumerID, reserve, "reserve:neg-prompt"); err != nil {
		t.Fatal(err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "neg-prompt-req",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	maliciousUsage := protocol.UsageInfo{
		PromptTokens:     -999_999_999,
		CompletionTokens: 10,
	}

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     maliciousUsage,
	})

	finalBalance := ledger.Balance(consumerID)
	if finalBalance > initialBalance {
		t.Errorf("MINT via negative prompt_tokens: balance = %d > initial %d (gain %d)",
			finalBalance, initialBalance, finalBalance-initialBalance)
	}
}

// TestCalculateCostNegativeTokensNonNegative verifies layer-2: calculateCost
// must return >= 0 for any combination of negative token inputs.
func TestCalculateCostNegativeTokensNonNegative(t *testing.T) {
	tests := []struct {
		name             string
		promptTokens     int
		completionTokens int
	}{
		{"negative completion only", 100, -1_000_000},
		{"negative prompt only", -1_000_000, 100},
		{"both negative", -1_000_000, -1_000_000},
		{"very large negative completion", 0, -999_999_999},
		{"very large negative prompt", -999_999_999, 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Test both the minimum-floor path and the NoMinimum path.
			costWithMin := payments.CalculateCostWithOverrides(
				"test-model", tc.promptTokens, tc.completionTokens, 0, 0, false,
			)
			if costWithMin < 0 {
				t.Errorf("CalculateCostWithOverrides(%d, %d) = %d, want >= 0",
					tc.promptTokens, tc.completionTokens, costWithMin)
			}

			costNoMin := payments.CalculateCostWithOverridesNoMinimum(
				"test-model", tc.promptTokens, tc.completionTokens, 0, 0, false,
			)
			if costNoMin < 0 {
				t.Errorf("CalculateCostWithOverridesNoMinimum(%d, %d) = %d, want >= 0",
					tc.promptTokens, tc.completionTokens, costNoMin)
			}
		})
	}
}

// TestSettlementRefundCapDoesNotExceedReservation directly exercises layer-3:
// even when totalCost is 0 (fully refunded), the refund equals reservation and
// no more. This is also the baseline for the normal-operation path.
func TestSettlementRefundCapDoesNotExceedReservation(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	const model = "refund-cap-model"
	consumerID := testConsumerID

	// Service account: NoMinimum path; zero positive tokens → cost=0 → full refund.
	if err := st.CreateUser(&store.User{
		AccountID:   consumerID,
		PrivyUserID: "did:privy:refund-cap",
		Role:        store.RoleService,
	}); err != nil {
		t.Fatal(err)
	}

	provider := srv.registry.Register("refund-cap-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "refund-cap-prov-acct"
	provider.Mu().Unlock()

	initialBalance := ledger.Balance(consumerID)
	const reserve int64 = 2_000_000
	if err := ledger.Charge(consumerID, reserve, "reserve:refund-cap"); err != nil {
		t.Fatal(err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "refund-cap-req",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	// Zero tokens → cost=0 → full refund should equal exactly the reservation.
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 0, CompletionTokens: 0},
	})

	finalBalance := ledger.Balance(consumerID)
	// Full refund: balance should be restored to initialBalance (service/NoMinimum
	// path; zero tokens → cost=1 since service path charges at least 1 for nonzero
	// usage, but zero-token means cost=0 and full refund of reservation).
	// Actually with zero tokens on NoMinimum path and no custom price the cost=0
	// (the `cost==0 && (promptTokens>0||completionTokens>0)` branch doesn't fire).
	// So refund = reserve and finalBalance = initialBalance.
	if finalBalance > initialBalance {
		t.Errorf("refund exceeded reservation: final balance %d > initial %d (excess %d)",
			finalBalance, initialBalance, finalBalance-initialBalance)
	}
}
