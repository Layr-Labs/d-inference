package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestRefundProviderExtraIdempotent verifies that the per-attempt provider
// top-up refund (used by cancelDispatch and the queue-path abandon branches)
// refunds exactly the extra above the shared base, and never double-refunds.
func TestRefundProviderExtraIdempotent(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	acct := testConsumerID
	base := ledger.Balance(acct) // $100 seeded by the harness
	if base <= 0 {
		t.Fatalf("expected seeded balance, got %d", base)
	}

	const baseReserve int64 = 1_000_000
	const extra int64 = 500_000
	pr := &registry.PendingRequest{
		RequestID:            "extra-refund-test",
		Model:                "m",
		ConsumerKey:          acct,
		BaseReservedMicroUSD: baseReserve,
		ReservedMicroUSD:     baseReserve + extra, // a provider top-up was charged
	}

	srv.refundProviderExtra(pr)
	if got := ledger.Balance(acct); got != base+extra {
		t.Errorf("after refund balance = %d, want %d (refunded extra %d)", got, base+extra, extra)
	}
	if pr.ReservedMicroUSD != baseReserve {
		t.Errorf("pr.ReservedMicroUSD = %d, want %d (reset to base)", pr.ReservedMicroUSD, baseReserve)
	}

	// Second call must be a no-op (no double refund).
	srv.refundProviderExtra(pr)
	if got := ledger.Balance(acct); got != base+extra {
		t.Errorf("second refund changed balance to %d, want %d (no double-refund)", got, base+extra)
	}
}

// TestRefundProviderExtraNoExtra verifies that when no top-up was charged
// (ReservedMicroUSD == BaseReservedMicroUSD), the refund is a no-op.
func TestRefundProviderExtraNoExtra(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	acct := testConsumerID
	base := ledger.Balance(acct)

	pr := &registry.PendingRequest{
		RequestID:            "no-extra",
		Model:                "m",
		ConsumerKey:          acct,
		BaseReservedMicroUSD: 1_000_000,
		ReservedMicroUSD:     1_000_000,
	}
	srv.refundProviderExtra(pr)
	if got := ledger.Balance(acct); got != base {
		t.Errorf("balance changed to %d, want %d (no extra to refund)", got, base)
	}
}
