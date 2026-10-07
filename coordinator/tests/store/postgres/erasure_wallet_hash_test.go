package postgres_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// wallet_hash is an unsalted hash of the wallet list. A finished request
// keeps neither the list nor its hash; TestErasureMarkerPostgres checks the
// scrub, this test checks cancel.
func TestErasureCancelClearsWalletHash(t *testing.T) {
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
	walletHash := func() string {
		t.Helper()
		var h string
		if err := s.pool.QueryRow(ctx, `SELECT wallet_hash FROM erasure_requests WHERE id = $1`, req.ID).Scan(&h); err != nil {
			t.Fatal(err)
		}
		return h
	}
	if walletHash() == "" {
		t.Fatal("a pending request has no wallet_hash; the test cannot see the clear")
	}
	if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if h := walletHash(); h != "" {
		t.Fatalf("wallet_hash after cancel = %q; want empty", h)
	}
}
