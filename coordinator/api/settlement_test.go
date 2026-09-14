package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// holdForSettlement refunds the reservation when no terminal arrives — the
// pre-existing leak (consumer disconnects mid-stream, provider never settles).
func TestHoldForSettlementRefundsOnExpiry(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	srv.settleGrace = 50 * time.Millisecond

	acct := testConsumerID
	base := ledger.Balance(acct)
	const reserved int64 = 2_000_000
	pr := &registry.PendingRequest{
		RequestID:            "settle-refund",
		Model:                "m",
		ConsumerKey:          acct,
		BaseReservedMicroUSD: reserved,
		ReservedMicroUSD:     reserved,
	}

	srv.holdForSettlement(pr)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if ledger.Balance(acct) == base+reserved {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := ledger.Balance(acct); got != base+reserved {
		t.Fatalf("balance after grace = %d, want %d (reservation refunded)", got, base+reserved)
	}
}

// When a terminal claims the parked record first, the grace timer must NOT also
// refund — the terminal path settles it. (Single-winner + FinalizeReservation.)
func TestHoldForSettlementClaimedNotRefunded(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	srv.settleGrace = 50 * time.Millisecond

	acct := testConsumerID
	base := ledger.Balance(acct)
	pr := &registry.PendingRequest{
		RequestID:            "settle-claimed",
		Model:                "m",
		ConsumerKey:          acct,
		BaseReservedMicroUSD: 1_000_000,
		ReservedMicroUSD:     1_000_000,
	}

	srv.holdForSettlement(pr)
	// Simulate the terminal handler claiming the record before grace expiry.
	if claimed := srv.claimSettlement("settle-claimed"); claimed != pr {
		t.Fatal("claimSettlement did not return the held record")
	}

	time.Sleep(200 * time.Millisecond) // let the grace timer fire (it should no-op)
	if got := ledger.Balance(acct); got != base {
		t.Fatalf("balance = %d, want %d (claimed record must not be auto-refunded)", got, base)
	}
}

// Defensive: a Server without a settlement holder still refunds rather than
// leaking the reservation.
func TestHoldForSettlementNilHolderRefunds(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	srv.settlements = nil
	acct := testConsumerID
	base := ledger.Balance(acct)
	const reserved int64 = 500_000
	pr := &registry.PendingRequest{
		RequestID:            "nil-holder",
		Model:                "m",
		ConsumerKey:          acct,
		BaseReservedMicroUSD: reserved,
		ReservedMicroUSD:     reserved,
	}
	srv.holdForSettlement(pr)
	if got := ledger.Balance(acct); got != base+reserved {
		t.Fatalf("balance = %d, want %d (nil holder must refund immediately)", got, base+reserved)
	}
}
