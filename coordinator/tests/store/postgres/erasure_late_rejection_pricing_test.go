package postgres_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"github.com/jackc/pgx/v5"
)

func personalRejection(a erasurefixture.Account) *store.RejectionRecord {
	return &store.RejectionRecord{
		RequestID: erasurefixture.UniqueID("req-rejected"), Endpoint: "/v1/chat/completions", Stage: "validation", ReasonCode: "model_not_found",
		HTTPStatus: 404, ConsumerKeyHash: store.HashKey(a.AccountID), RequestedModel: "personal-model", ResolvedModel: "personal-resolved",
		Params: json.RawMessage(`{"user":"personal-param"}`),
	}
}

// personalRejectionRows counts the account's rejection rows that keep a model
// name or parameters, and all its rejection rows.
func personalRejectionRows(t *testing.T, s *postgresFixture, a erasurefixture.Account) (personal, all int) {
	t.Helper()
	if err := s.pool.QueryRow(context.Background(), `SELECT
	  count(*) FILTER (WHERE requested_model <> '' OR resolved_model <> '' OR params IS NOT NULL), count(*)
	  FROM request_rejections WHERE consumer_key_hash = $1`, store.HashKey(a.AccountID)).Scan(&personal, &all); err != nil {
		t.Fatal(err)
	}
	return personal, all
}

// lockTable holds an ACCESS EXCLUSIVE lock on table until the returned
// function commits it.
func lockTable(t *testing.T, s *postgresFixture, table string) func() {
	t.Helper()
	ctx := context.Background()
	blocker, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = blocker.Rollback(ctx) })
	if _, err := blocker.Exec(ctx, `LOCK TABLE `+pgx.Identifier{table}.Sanitize()+` IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	return func() {
		t.Helper()
		if err := blocker.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
}

// A rejection record admitted before the scrub holds the shared personal
// write fence. The scrub waits for it and then clears the row it wrote.
func TestErasureScrubClearsRejectionAdmittedBeforeIt(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	release := lockTable(t, s, "request_rejections")
	writer := make(chan error, 1)
	go func() { writer <- s.RecordRejection(personalRejection(a)) }()
	waitErasureLock(t, s, "INSERT INTO request_rejections", 1)
	scrub := make(chan error, 1)
	go func() { _, err := s.ScrubAccount(ctx, req.ID, now); scrub <- err }()
	waitErasureLock(t, s, "pg_advisory_xact_lock(714320, 2)", 1)
	release()
	if err := <-writer; err != nil {
		t.Fatal(err)
	}
	if err := <-scrub; err != nil {
		t.Fatal(err)
	}
	if personal, all := personalRejectionRows(t, s, a); all != 1 || personal != 0 {
		t.Fatalf("rejection rows = %d, %d with personal fields; want 1 cleared row", all, personal)
	}
}

// A rejection record that arrives while the scrub runs waits for the scrub's
// exclusive fence, sees the erased account and writes no personal fields.
func TestErasureLateRejectionWaitsForScrubAndKeepsNoPersonalFields(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	release := lockTable(t, s, "request_rejections")
	scrub := make(chan error, 1)
	go func() { _, err := s.ScrubAccount(ctx, req.ID, now); scrub <- err }()
	waitErasureLock(t, s, "FROM request_rejections WHERE consumer_key_hash", 1)
	writer := make(chan error, 1)
	go func() { writer <- s.RecordRejection(personalRejection(a)) }()
	waitErasureLock(t, s, "pg_advisory_xact_lock_shared(714320, 2)", 1)
	release()
	if err := <-scrub; err != nil {
		t.Fatal(err)
	}
	if err := <-writer; err != nil {
		t.Fatal(err)
	}
	if personal, all := personalRejectionRows(t, s, a); all != 1 || personal != 0 {
		t.Fatalf("rejection rows = %d, %d with personal fields; want 1 row without them", all, personal)
	}
	// A record that arrives later still keeps no personal fields.
	if err := s.RecordRejection(personalRejection(a)); err != nil {
		t.Fatal(err)
	}
	if personal, all := personalRejectionRows(t, s, a); all != 2 || personal != 0 {
		t.Fatalf("rejection rows = %d, %d with personal fields; want 2 rows without them", all, personal)
	}
}

// A price write admitted before the confirm holds the user fence; the
// confirm waits for it, and the scrub then deletes the price.
func TestErasureScrubDeletesPriceAdmittedBeforeConfirm(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	release := lockTable(t, s, "model_prices")
	writer := make(chan error, 1)
	go func() {
		writer <- s.SetModelPrice(store.ModelPrice{AccountID: a.AccountID, Model: "personal-model", InputPrice: 1, OutputPrice: 2})
	}()
	waitErasureLock(t, s, "INSERT INTO model_prices", 1)
	confirm := make(chan *store.ErasureRequest, 1)
	go func() {
		req, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Actor: "admin_key", Now: now})
		if err != nil {
			t.Error(err)
		}
		confirm <- req
	}()
	waitErasureLock(t, s, "FOR UPDATE", 1)
	release()
	if err := <-writer; err != nil {
		t.Fatalf("price write admitted before the confirm: %v", err)
	}
	req := <-confirm
	if req == nil {
		t.FailNow()
	}
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	if prices := s.ListModelPrices(a.AccountID); len(prices) != 0 {
		t.Fatalf("prices after the scrub = %+v; want none", prices)
	}
}

// A price write that arrives while the confirm runs waits for the user
// fence, sees the soft-deleted account and writes nothing. A write after the
// scrub is refused too.
func TestErasureLatePriceWaitsForConfirmAndIsRefused(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	release := lockTable(t, s, "api_keys")
	confirm := make(chan *store.ErasureRequest, 1)
	go func() {
		req, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Actor: "admin_key", Now: now})
		if err != nil {
			t.Error(err)
		}
		confirm <- req
	}()
	waitErasureLock(t, s, "FROM api_keys a", 1)
	writer := make(chan error, 1)
	price := store.ModelPrice{AccountID: a.AccountID, Model: "personal-model", InputPrice: 1, OutputPrice: 2}
	go func() { writer <- s.SetModelPrice(price) }()
	waitErasureLock(t, s, "FOR SHARE", 1)
	release()
	req := <-confirm
	if req == nil {
		t.FailNow()
	}
	if err := <-writer; !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("price write that waited for the confirm: %v; want ErrErasureConflict", err)
	}
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	if err := s.SetModelPrice(price); !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("price write after the scrub: %v; want ErrErasureConflict", err)
	}
	if prices := s.ListModelPrices(a.AccountID); len(prices) != 0 {
		t.Fatalf("prices = %+v; want none", prices)
	}
}
