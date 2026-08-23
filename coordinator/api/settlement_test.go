package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

type settlementTestTimer struct {
	callbacks []func()
}

func (timer *settlementTestTimer) afterFunc(_ time.Duration, callback func()) *time.Timer {
	timer.callbacks = append(timer.callbacks, callback)
	return nil
}

func (timer *settlementTestTimer) fireNext(t *testing.T) {
	t.Helper()
	if len(timer.callbacks) == 0 {
		t.Fatal("no settlement expiry callback scheduled")
	}
	callback := timer.callbacks[0]
	timer.callbacks = timer.callbacks[1:]
	callback()
}

func installSettlementTestTimer(srv *Server) *settlementTestTimer {
	timer := &settlementTestTimer{}
	srv.settlements = newSettlementHolderWithTimer(timer.afterFunc)
	return timer
}

func TestSettlementHolderClaimBeatsExpiry(t *testing.T) {
	timer := &settlementTestTimer{}
	holder := newSettlementHolderWithTimer(timer.afterFunc)
	pr := &registry.PendingRequest{RequestID: "r1"}
	expired := false
	holder.hold(pr, time.Hour, func(*registry.PendingRequest) { expired = true })

	if got := holder.claim("r1"); got != pr {
		t.Fatalf("claim returned %v, want the held request", got)
	}
	if got := holder.claim("r1"); got != nil {
		t.Fatal("second claim returned an already-consumed record")
	}
	timer.fireNext(t)
	if expired {
		t.Fatal("expiry callback ran for an already-claimed record")
	}
}

func TestSettlementHolderExpiryFiresExactlyOnce(t *testing.T) {
	timer := &settlementTestTimer{}
	holder := newSettlementHolderWithTimer(timer.afterFunc)
	pr := &registry.PendingRequest{RequestID: "r2"}
	var expired []*registry.PendingRequest
	holder.hold(pr, time.Hour, func(got *registry.PendingRequest) {
		expired = append(expired, got)
	})

	timer.fireNext(t)
	if len(expired) != 1 || expired[0] != pr {
		t.Fatalf("expiry callbacks = %v, want exactly the held request", expired)
	}
	if got := holder.claim("r2"); got != nil {
		t.Fatal("record remained claimable after expiry")
	}
}

func TestHoldForSettlementRefundsOnExpiry(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	timer := installSettlementTestTimer(srv)
	account := testConsumerID
	base := ledger.Balance(account)
	const reserved int64 = 2_000_000
	pr := &registry.PendingRequest{
		RequestID:            "settle-refund",
		Model:                "m",
		ConsumerKey:          account,
		BaseReservedMicroUSD: reserved,
		ReservedMicroUSD:     reserved,
	}

	srv.holdForSettlement(pr)
	timer.fireNext(t)
	if got := ledger.Balance(account); got != base+reserved {
		t.Fatalf("balance after expiry = %d, want %d", got, base+reserved)
	}
}

func TestHoldForSettlementClaimedNotRefunded(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	timer := installSettlementTestTimer(srv)
	account := testConsumerID
	base := ledger.Balance(account)
	pr := &registry.PendingRequest{
		RequestID:            "settle-claimed",
		Model:                "m",
		ConsumerKey:          account,
		BaseReservedMicroUSD: 1_000_000,
		ReservedMicroUSD:     1_000_000,
	}

	srv.holdForSettlement(pr)
	if claimed := srv.claimSettlement(pr.RequestID); claimed != pr {
		t.Fatal("claimSettlement did not return the held record")
	}
	timer.fireNext(t)
	if got := ledger.Balance(account); got != base {
		t.Fatalf("balance after claimed expiry = %d, want unchanged %d", got, base)
	}
}

func TestHoldForSettlementNilHolderRefunds(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	srv.settlements = nil
	account := testConsumerID
	base := ledger.Balance(account)
	const reserved int64 = 500_000
	pr := &registry.PendingRequest{
		RequestID:            "nil-holder",
		Model:                "m",
		ConsumerKey:          account,
		BaseReservedMicroUSD: reserved,
		ReservedMicroUSD:     reserved,
	}
	srv.holdForSettlement(pr)
	if got := ledger.Balance(account); got != base+reserved {
		t.Fatalf("balance = %d, want %d", got, base+reserved)
	}
}
