package postgres_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureRetainsOnlyHashedSEOwnership(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	a := erasurefixture.SeedAccount(t, s)
	key := erasurefixture.UniqueID("historical-private-SE")
	if _, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: erasurefixture.UniqueID("historical"), AccountID: a.AccountID, SEKey: key, At: time.Now(), Disconnected: true}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM erasure_se_owners WHERE account_id=$1 AND se_key_digest=$2`, a.AccountID, erasure.LegacySEDigest(key)).Scan(&count); err != nil || count != 1 {
		t.Fatalf("retained ownership count=%d err=%v", count, err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM darkbloom_machine_aliases WHERE scope=$1`, a.AccountID).Scan(&count); err != nil || count != 0 {
		t.Fatalf("personal aliases count=%d err=%v", count, err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM pg_index WHERE indrelid='erasure_se_owners'::regclass AND indisvalid AND indisready`).Scan(&count); err != nil || count != 2 {
		t.Fatalf("ownership indexes=%d err=%v", count, err)
	}
}

func TestProviderOwnershipPublicationSharesErasureFence(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	a := erasurefixture.SeedAccount(t, s)
	p, err := s.GetProviderRecord(ctx, a.ProviderID)
	if err != nil {
		t.Fatal(err)
	}
	hold, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(ctx)
	if _, err := hold.Exec(ctx, `SELECT pg_advisory_xact_lock(714320,2)`); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 2)
	go func() { done <- s.UpsertProvider(ctx, *p) }()
	second := *p
	second.ID = erasurefixture.UniqueID("co-owner")
	go func() { done <- s.UpsertProviderWithReputation(ctx, second, store.ReputationRecord{}) }()
	waitErasureLock(t, s, "pg_advisory_xact_lock_shared(714320, 2)", 2)
	if err := hold.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}
