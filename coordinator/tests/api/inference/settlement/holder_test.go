package settlement_test

import (
	"testing"
	"time"

	latesettlement "github.com/eigeninference/d-inference/coordinator/internal/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// settlementHolder: claim before expiry wins and the expiry callback never runs.
func TestSettlementHolderClaimBeatsExpiry(t *testing.T) {
	h := latesettlement.New()
	pr := &registry.PendingRequest{RequestID: "r1"}
	expired := make(chan struct{}, 1)
	h.Hold(pr, 100*time.Millisecond, func(*registry.PendingRequest) { expired <- struct{}{} })

	if got := h.Claim("r1"); got != pr {
		t.Fatalf("claim returned %v, want the held pr", got)
	}
	if got := h.Claim("r1"); got != nil {
		t.Fatal("second claim should return nil (record consumed)")
	}
	select {
	case <-expired:
		t.Fatal("expiry callback ran for an already-claimed record")
	case <-time.After(250 * time.Millisecond):
	}
}

// settlementHolder: with no claim, the expiry callback fires exactly once.
func TestSettlementHolderExpiryFires(t *testing.T) {
	h := latesettlement.New()
	pr := &registry.PendingRequest{RequestID: "r2"}
	got := make(chan *registry.PendingRequest, 2)
	h.Hold(pr, 30*time.Millisecond, func(p *registry.PendingRequest) { got <- p })

	select {
	case p := <-got:
		if p != pr {
			t.Fatalf("expiry got %v, want held pr", p)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expiry callback never fired")
	}
	if c := h.Claim("r2"); c != nil {
		t.Fatal("record should be gone after expiry claimed it")
	}
}
