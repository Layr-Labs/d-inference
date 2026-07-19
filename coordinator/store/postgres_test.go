package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresInferenceRouteErrorReasonUpsertQualifiesTargetColumn(t *testing.T) {
	if !strings.Contains(inferenceRouteErrorReasonUpsertAssignment, "inference_routes.error_reason") {
		t.Fatalf("error_reason upsert fallback must qualify target table: %s", inferenceRouteErrorReasonUpsertAssignment)
	}
	if strings.Contains(inferenceRouteErrorReasonUpsertAssignment, "), error_reason)") {
		t.Fatalf("error_reason upsert fallback is ambiguous in ON CONFLICT: %s", inferenceRouteErrorReasonUpsertAssignment)
	}
}

func TestPostgresSeedKey(t *testing.T) {
	s := testPostgresStore(t)

	err := s.SeedKey("my-admin-key")
	if err != nil {
		t.Fatalf("SeedKey: %v", err)
	}

	if !s.ValidateKey("my-admin-key") {
		t.Error("seeded key should be valid")
	}

	// Seeding the same key again should be a no-op.
	err = s.SeedKey("my-admin-key")
	if err != nil {
		t.Fatalf("SeedKey (duplicate): %v", err)
	}

	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestPostgresProviderRecordStatsPersisted(t *testing.T) {
	s := testPostgresStore(t)

	rec := ProviderRecord{
		ID:                         "provider-1",
		Hardware:                   []byte(`{"chip":"M4 Max"}`),
		Models:                     []byte(`["model-a"]`),
		Backend:                    "vllm_mlx",
		TrustLevel:                 "hardware",
		Attested:                   true,
		SEPublicKey:                "se-key",
		SerialNumber:               "serial-1",
		LifetimeRequestsServed:     42,
		LifetimeTokensGenerated:    1234,
		LastSessionRequestsServed:  7,
		LastSessionTokensGenerated: 222,
		RegisteredAt:               time.Now(),
		LastSeen:                   time.Now(),
	}

	if err := s.UpsertProvider(context.Background(), rec); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}

	got, err := s.GetProviderRecord(context.Background(), "provider-1")
	if err != nil {
		t.Fatalf("GetProviderRecord: %v", err)
	}

	if got.LifetimeRequestsServed != rec.LifetimeRequestsServed {
		t.Errorf("lifetime_requests_served = %d, want %d", got.LifetimeRequestsServed, rec.LifetimeRequestsServed)
	}
	if got.LifetimeTokensGenerated != rec.LifetimeTokensGenerated {
		t.Errorf("lifetime_tokens_generated = %d, want %d", got.LifetimeTokensGenerated, rec.LifetimeTokensGenerated)
	}
	if got.LastSessionRequestsServed != rec.LastSessionRequestsServed {
		t.Errorf("last_session_requests_served = %d, want %d", got.LastSessionRequestsServed, rec.LastSessionRequestsServed)
	}
	if got.LastSessionTokensGenerated != rec.LastSessionTokensGenerated {
		t.Errorf("last_session_tokens_generated = %d, want %d", got.LastSessionTokensGenerated, rec.LastSessionTokensGenerated)
	}
}

// --- Stripe Connect (postgres-backed) ---
//
// The memory store has happy-path coverage; these tests verify the postgres
// schema migrations + queries match the interface contract. Skipped unless
// DATABASE_URL is set, so unit-test runs without postgres still pass.

func TestPostgresSetUserStripeAccount(t *testing.T) {
	s := testPostgresStore(t)

	u := &User{AccountID: "acct-pg-1", PrivyUserID: "did:privy:pg1", Email: "a@b"}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("create user: %v", err)
	}

	if err := s.SetUserStripeAccount("acct-pg-1", "acct_123", "ready", "US", "card", "4242", true); err != nil {
		t.Fatalf("set stripe account: %v", err)
	}

	got, err := s.GetUserByAccountID("acct-pg-1")
	if err != nil {
		t.Fatalf("get user: %v", err)
	}
	if got.StripeAccountID != "acct_123" {
		t.Errorf("StripeAccountID = %q, want acct_123", got.StripeAccountID)
	}
	if got.StripeAccountStatus != "ready" {
		t.Errorf("status = %q", got.StripeAccountStatus)
	}
	if got.StripeAccountCountry != "US" {
		t.Errorf("StripeAccountCountry = %q, want US", got.StripeAccountCountry)
	}
	if got.StripeDestinationType != "card" || got.StripeDestinationLast4 != "4242" {
		t.Errorf("destination = %q ••%q", got.StripeDestinationType, got.StripeDestinationLast4)
	}
	if !got.StripeInstantEligible {
		t.Error("instant_eligible should be true")
	}

	// Updating without a country should leave it unchanged.
	if err := s.SetUserStripeAccount("acct-pg-1", "acct_123", "restricted", "", "card", "4242", true); err != nil {
		t.Fatalf("set stripe account without country: %v", err)
	}
	got, _ = s.GetUserByAccountID("acct-pg-1")
	if got.StripeAccountCountry != "US" {
		t.Errorf("StripeAccountCountry after no-country update = %q, want US", got.StripeAccountCountry)
	}

	// Lookup by stripe account ID.
	got2, err := s.GetUserByStripeAccount("acct_123")
	if err != nil {
		t.Fatalf("get by stripe acct: %v", err)
	}
	if got2.AccountID != "acct-pg-1" {
		t.Errorf("AccountID = %q, want acct-pg-1", got2.AccountID)
	}
}

func TestPostgresStripeAutoWithdrawPreferenceLifecycle(t *testing.T) {
	s := testPostgresStore(t)
	user := &User{AccountID: "acct-pg-auto-pref", PrivyUserID: "did:privy:pg-auto-pref"}
	if err := s.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(user.AccountID, "acct_pg_auto_a", "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Truncate(time.Second)
	due := now.Add(-time.Hour)
	if err := s.SetStripeAutoWithdraw(user.AccountID, "acct_pg_auto_a", true, now.Add(-2*time.Hour), due); err != nil {
		t.Fatal(err)
	}
	// Idempotent enable must not postpone the already-authorized slot.
	if err := s.SetStripeAutoWithdraw(user.AccountID, "acct_pg_auto_a", true, now, now.Add(7*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetUserByAccountID(user.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.StripeAutoWithdrawEnabled || got.StripeAutoWithdrawNextAt == nil ||
		!got.StripeAutoWithdrawNextAt.Equal(due) {
		t.Fatalf("preference = %+v, want enabled at %s", got, due)
	}
	users, err := s.ListUsersDueForStripeAutoWithdraw(now, 10)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, candidate := range users {
		if candidate.AccountID == user.AccountID {
			found = true
		}
	}
	if !found {
		t.Fatalf("due users did not include %s: %+v", user.AccountID, users)
	}

	next := now.Add(7 * 24 * time.Hour)
	advanced, err := s.AdvanceStripeAutoWithdraw(user.AccountID, due, next)
	if err != nil || !advanced {
		t.Fatalf("advance = %v, err = %v", advanced, err)
	}
	advanced, err = s.AdvanceStripeAutoWithdraw(user.AccountID, due, next.Add(7*24*time.Hour))
	if err != nil || advanced {
		t.Fatalf("stale advance = %v, err = %v", advanced, err)
	}

	if err := s.SetUserStripeAccount(user.AccountID, "acct_pg_auto_b", "ready", "US", "bank", "9999", false); err != nil {
		t.Fatal(err)
	}
	got, _ = s.GetUserByAccountID(user.AccountID)
	if got.StripeAutoWithdrawEnabled || got.StripeAutoWithdrawAuthorizedAt != nil ||
		got.StripeAutoWithdrawNextAt != nil {
		t.Fatalf("destination replacement did not revoke preference: %+v", got)
	}
	err = s.SetStripeAutoWithdraw(
		user.AccountID, "acct_pg_auto_a", true, now, next,
	)
	if !errors.Is(err, ErrAutoWithdrawNotAuthorized) {
		t.Fatalf("stale destination err = %v, want ErrAutoWithdrawNotAuthorized", err)
	}
	applied, err := s.SetUserStripeAccountIfCurrent(
		user.AccountID, "acct_pg_auto_a", "", "", "", "", "", false,
	)
	if err != nil || applied {
		t.Fatalf("stale account CAS = %v, err = %v", applied, err)
	}
	got, _ = s.GetUserByAccountID(user.AccountID)
	if got.StripeAccountID != "acct_pg_auto_b" {
		t.Fatalf("stale account CAS overwrote destination: %+v", got)
	}
}

// CreateUser must persist create-time Role and PlatformFeePercent (parity with
// the in-memory store), so one-call provisioning of a service account survives.
func TestPostgresCreateUserPersistsRoleAndFee(t *testing.T) {
	s := testPostgresStore(t)

	zero := int64(0)
	u := &User{
		AccountID:          "acct-pg-svc",
		PrivyUserID:        "did:privy:pgsvc",
		Email:              "svc@b",
		Role:               RoleService,
		PlatformFeePercent: &zero,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("create user: %v", err)
	}

	got, err := s.GetUserByAccountID("acct-pg-svc")
	if err != nil {
		t.Fatalf("get user: %v", err)
	}
	if got.Role != RoleService {
		t.Errorf("role = %q, want %q (dropped on insert)", got.Role, RoleService)
	}
	if got.PlatformFeePercent == nil || *got.PlatformFeePercent != 0 {
		t.Errorf("platform_fee_percent = %v, want 0 (dropped on insert)", got.PlatformFeePercent)
	}

	// A plain user still round-trips with no role and a nil fee override.
	if err := s.CreateUser(&User{AccountID: "acct-pg-plain", PrivyUserID: "did:privy:pgplain", Email: "p@b"}); err != nil {
		t.Fatalf("create plain user: %v", err)
	}
	plain, err := s.GetUserByAccountID("acct-pg-plain")
	if err != nil {
		t.Fatal(err)
	}
	if plain.Role != "" || plain.PlatformFeePercent != nil {
		t.Errorf("plain user = role %q fee %v, want empty/nil", plain.Role, plain.PlatformFeePercent)
	}
}

func TestPostgresSetUserStripeAccountUserNotFound(t *testing.T) {
	s := testPostgresStore(t)
	err := s.SetUserStripeAccount("nope", "acct_x", "pending", "", "", "", false)
	if err == nil {
		t.Fatal("expected error for missing user")
	}
}

func TestPostgresStripeWithdrawalCRUD(t *testing.T) {
	s := testPostgresStore(t)

	u := &User{AccountID: "acct-pg-wd", PrivyUserID: "did:privy:pgwd"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-wd", "acct_wd", "ready", "", "bank", "6789", false)

	wd := &StripeWithdrawal{
		ID:              "wd-pg-1",
		AccountID:       "acct-pg-wd",
		StripeAccountID: "acct_wd",
		AmountMicroUSD:  5_000_000,
		FeeMicroUSD:     0,
		NetMicroUSD:     5_000_000,
		Method:          "standard",
		Status:          "pending",
	}
	if err := s.CreateStripeWithdrawal(wd); err != nil {
		t.Fatalf("create: %v", err)
	}

	// Round-trip by id.
	got, err := s.GetStripeWithdrawal("wd-pg-1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.AmountMicroUSD != 5_000_000 || got.Status != "pending" || got.Method != "standard" {
		t.Errorf("got = %+v", got)
	}

	// Update with transfer + payout IDs and flip to paid.
	got.TransferID = "tr_pg_1"
	got.PayoutID = "po_pg_1"
	got.Status = "paid"
	if err := s.UpdateStripeWithdrawal(got); err != nil {
		t.Fatalf("update: %v", err)
	}

	// Lookups by transfer/payout id.
	byTr, err := s.GetStripeWithdrawalByTransferID("tr_pg_1")
	if err != nil {
		t.Fatalf("get by transfer: %v", err)
	}
	if byTr.ID != "wd-pg-1" {
		t.Errorf("byTr.ID = %q", byTr.ID)
	}
	byPo, err := s.GetStripeWithdrawalByPayoutID("po_pg_1")
	if err != nil {
		t.Fatalf("get by payout: %v", err)
	}
	if byPo.Status != "paid" {
		t.Errorf("status = %q", byPo.Status)
	}
	if byPo.FeeRefunded {
		t.Error("FeeRefunded should default to false")
	}

	// FeeRefunded round-trips (idempotency key for instant-fee refunds).
	byPo.FeeRefunded = true
	if err := s.UpdateStripeWithdrawal(byPo); err != nil {
		t.Fatalf("update fee_refunded: %v", err)
	}
	if again, _ := s.GetStripeWithdrawal("wd-pg-1"); !again.FeeRefunded {
		t.Error("FeeRefunded not persisted")
	}

	// Misses wrap ErrNotFound so the webhook state machine can distinguish
	// a true miss from a transient failure.
	if _, err := s.GetStripeWithdrawalByPayoutID("po_pg_missing"); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing payout lookup err = %v, want ErrNotFound", err)
	}
	if _, err := s.GetStripeWithdrawalByTransferID("tr_pg_missing"); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing transfer lookup err = %v, want ErrNotFound", err)
	}

	// Reference-idempotent refund credit: second call with the same
	// (account, type, reference) is skipped.
	applied, err := s.CreditWithdrawableOnce("acct-pg-wd", 500_000, LedgerRefund, "stripe_withdraw_fee:wd-pg-1")
	if err != nil || !applied {
		t.Fatalf("first CreditWithdrawableOnce: applied=%v err=%v", applied, err)
	}
	applied, err = s.CreditWithdrawableOnce("acct-pg-wd", 500_000, LedgerRefund, "stripe_withdraw_fee:wd-pg-1")
	if err != nil || applied {
		t.Fatalf("duplicate CreditWithdrawableOnce: applied=%v err=%v, want skipped", applied, err)
	}
	if bal := s.GetBalance("acct-pg-wd"); bal != 500_000 {
		t.Errorf("balance = %d, want 500_000 (credited exactly once)", bal)
	}

	// List for account.
	list, err := s.ListStripeWithdrawals("acct-pg-wd", 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(list) != 1 || list[0].ID != "wd-pg-1" {
		t.Errorf("list = %+v", list)
	}
}

func TestPostgresStripeWithdrawalRefundFlag(t *testing.T) {
	s := testPostgresStore(t)
	u := &User{AccountID: "acct-pg-rf", PrivyUserID: "did:privy:pgrf"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-rf", "acct_rf", "ready", "", "bank", "1", false)

	wd := &StripeWithdrawal{
		ID: "wd-pg-rf", AccountID: "acct-pg-rf", StripeAccountID: "acct_rf",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", PayoutID: "po_rf",
	}
	if err := s.CreateStripeWithdrawal(wd); err != nil {
		t.Fatalf("create: %v", err)
	}

	wd.Status = "failed"
	wd.Refunded = true
	wd.FailureReason = "account_closed: bank closed"
	if err := s.UpdateStripeWithdrawal(wd); err != nil {
		t.Fatalf("update: %v", err)
	}

	got, _ := s.GetStripeWithdrawal("wd-pg-rf")
	if !got.Refunded {
		t.Error("refunded should be true after update")
	}
	if got.FailureReason != "account_closed: bank closed" {
		t.Errorf("failure_reason = %q", got.FailureReason)
	}
}

func TestPostgresStripeWithdrawalDuplicateIDRejected(t *testing.T) {
	s := testPostgresStore(t)
	u := &User{AccountID: "acct-pg-dup", PrivyUserID: "did:privy:pgdup"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-dup", "acct_dup", "ready", "", "bank", "1", false)

	wd := &StripeWithdrawal{
		ID: "wd-dup", AccountID: "acct-pg-dup", StripeAccountID: "acct_dup",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000, Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawal(wd); err != nil {
		t.Fatalf("create #1: %v", err)
	}
	if err := s.CreateStripeWithdrawal(wd); err == nil {
		t.Fatal("expected duplicate ID to be rejected")
	}
}

// newPostgresWithMaxConns creates a PostgresStore with a specific pool size.
func newPostgresWithMaxConns(t *testing.T, maxConns int32) *PostgresStore {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.MaxConns = maxConns
	cfg.MinConns = 0

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	s := &PostgresStore{pool: pool}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		t.Fatalf("migrate: %v", err)
	}
	for _, table := range []string{"providers"} {
		if _, err := s.pool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPoolExhaustion_SmallPool(t *testing.T) {
	s := newPostgresWithMaxConns(t, 2)

	const numProviders = 40
	errs := make(chan error, numProviders)

	for i := 0; i < numProviders; i++ {
		go func(id int) {
			p := ProviderRecord{
				ID:           fmt.Sprintf("provider-exhaust-%d", id),
				Hardware:     json.RawMessage(`{"chip":"Apple M3 Max"}`),
				Models:       json.RawMessage(`[]`),
				Backend:      "vllm_mlx",
				TrustLevel:   "self_signed",
				RegisteredAt: time.Now(),
				LastSeen:     time.Now(),
			}
			errs <- s.UpsertProvider(context.Background(), p)
		}(i)
	}

	var failures int
	for i := 0; i < numProviders; i++ {
		if err := <-errs; err != nil {
			failures++
		}
	}

	if failures == 0 {
		t.Log("no failures with pool_max_conns=2 — query was fast enough to avoid exhaustion on this machine")
	} else {
		t.Logf("pool_max_conns=2: %d/%d upserts failed (expected — pool exhaustion)", failures, numProviders)
	}
}

// TestPoolExhaustion_SimulatedLatency reproduces the prod failure:
// 2 pool connections + 40 goroutines each holding a connection for 500ms
// (simulating EigenCloud→RDS network latency). Most goroutines timeout
// waiting in the pool queue — exactly what happens in production.
func TestPoolExhaustion_SimulatedLatency(t *testing.T) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.MaxConns = 2
	cfg.MinConns = 0

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	defer pool.Close()

	const numWorkers = 40
	errs := make(chan error, numWorkers)

	for i := 0; i < numWorkers; i++ {
		go func() {
			qctx, qcancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer qcancel()
			_, err := pool.Exec(qctx, "SELECT pg_sleep(0.5)")
			errs <- err
		}()
	}

	var failures int
	for i := 0; i < numWorkers; i++ {
		if err := <-errs; err != nil {
			failures++
		}
	}

	t.Logf("pool_max_conns=2 + 500ms latency: %d/%d queries failed", failures, numWorkers)
	if failures == 0 {
		t.Error("expected some failures with only 2 connections and 500ms queries")
	}
}

func TestPoolExhaustion_AdequatePool(t *testing.T) {
	s := newPostgresWithMaxConns(t, 20)

	const numProviders = 40
	errs := make(chan error, numProviders)

	for i := 0; i < numProviders; i++ {
		go func(id int) {
			p := ProviderRecord{
				ID:           fmt.Sprintf("provider-ok-%d", id),
				Hardware:     json.RawMessage(`{"chip":"Apple M3 Max"}`),
				Models:       json.RawMessage(`[]`),
				Backend:      "vllm_mlx",
				TrustLevel:   "self_signed",
				RegisteredAt: time.Now(),
				LastSeen:     time.Now(),
			}
			errs <- s.UpsertProvider(context.Background(), p)
		}(i)
	}

	var failures int
	for i := 0; i < numProviders; i++ {
		if err := <-errs; err != nil {
			failures++
			t.Errorf("upsert failed with adequate pool: %v", err)
		}
	}

	if failures > 0 {
		t.Fatalf("pool_max_conns=20: %d/%d upserts failed — should not happen", failures, numProviders)
	}
	t.Logf("pool_max_conns=20: all %d upserts succeeded", numProviders)
}

// TestPostgresWalletPriceCleanupPreservesPlatform guards against the regression
// where the one-time model_prices cleanup wiped platform-default pricing. When
// the cleanup runs it must remove orphan wallet-keyed rows (account_id not in
// users) but preserve the synthetic account_id="platform" (which holds platform
// pricing and is never a users row) and real user-backed prices. The marker is
// cleared first so the guarded cleanup actually executes.
func TestPostgresWalletPriceCleanupPreservesPlatform(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	// model_prices and schema_migrations are not in the harness truncate list;
	// reset them explicitly so the cleanup runs and assertions are deterministic.
	if _, err := s.pool.Exec(ctx, "DELETE FROM model_prices"); err != nil {
		t.Fatalf("clean model_prices: %v", err)
	}
	if _, err := s.pool.Exec(ctx, "DELETE FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1'"); err != nil {
		t.Fatalf("clear migration marker: %v", err)
	}

	// A real, user-backed custom price (must survive the cleanup).
	if err := s.CreateUser(&User{AccountID: "acct-real", PrivyUserID: "did:privy:real"}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	if err := s.SetModelPrice("acct-real", "gemma-4-26b", 65_000, 200_000); err != nil {
		t.Fatalf("set user price: %v", err)
	}
	// Platform-default pricing (the bug under test — must survive).
	if err := s.SetModelPrice("platform", "gpt-oss-20b", 50_000, 200_000); err != nil {
		t.Fatalf("set platform price: %v", err)
	}
	// An orphan wallet-keyed price whose account is NOT in users (exactly what
	// the cleanup is meant to remove).
	if err := s.SetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b", 1, 2); err != nil {
		t.Fatalf("set orphan wallet price: %v", err)
	}

	// Re-run migrations (simulated restart). With the marker cleared, the
	// guarded cleanup executes exactly once.
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	if in, out, ok := s.GetModelPrice("platform", "gpt-oss-20b"); !ok || in != 50_000 || out != 200_000 {
		t.Errorf("platform price = (%d, %d, %v), want (50000, 200000, true) — platform pricing must never be wiped", in, out, ok)
	}
	if in, out, ok := s.GetModelPrice("acct-real", "gemma-4-26b"); !ok || in != 65_000 || out != 200_000 {
		t.Errorf("user price = (%d, %d, %v), want (65000, 200000, true)", in, out, ok)
	}
	if _, _, ok := s.GetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b"); ok {
		t.Error("orphan wallet-keyed price should be removed by the cleanup")
	}

	// The cleanup must record its marker so it does not run again.
	var marked bool
	if err := s.pool.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1')").Scan(&marked); err != nil {
		t.Fatalf("check marker: %v", err)
	}
	if !marked {
		t.Error("cleanup marker should be set after the cleanup runs")
	}
}

// TestPostgresWalletPriceCleanupRunsOnce verifies the destructive cleanup is
// gated behind its schema_migrations marker and does NOT run on every boot. Once
// the marker is set, a subsequent migrate() leaves even orphan wallet-keyed rows
// untouched — stopping the destructive DELETE from running repeatedly.
func TestPostgresWalletPriceCleanupRunsOnce(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	if _, err := s.pool.Exec(ctx, "DELETE FROM model_prices"); err != nil {
		t.Fatalf("clean model_prices: %v", err)
	}
	// Mark the cleanup as already done.
	if _, err := s.pool.Exec(ctx,
		"INSERT INTO schema_migrations (id) VALUES ('cleanup_wallet_model_prices_v1') ON CONFLICT (id) DO NOTHING"); err != nil {
		t.Fatalf("set migration marker: %v", err)
	}

	// An orphan wallet-keyed row added after the marker is set must survive,
	// because the guarded cleanup is skipped on subsequent boots.
	if err := s.SetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b", 1, 2); err != nil {
		t.Fatalf("set orphan wallet price: %v", err)
	}

	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	if _, _, ok := s.GetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b"); !ok {
		t.Error("orphan row should survive when the cleanup marker is already set (run-once)")
	}
}

// TestPostgresDeleteProvidersBySerial is the FK-ordering regression: a
// raw DELETE FROM providers fails when a provider_reputation row exists (the FK
// has no ON DELETE CASCADE), so the delete must remove reputation first. It also
// proves earnings (money history) survive the delete.
func TestPostgresDeleteProvidersBySerial(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	// Owner rows (two sessions, one serial) + a guard row for another account.
	for _, rec := range []ProviderRecord{
		{ID: "a", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "vllm_mlx", SerialNumber: "SER", AccountID: "acct-1", RegisteredAt: time.Now(), LastSeen: time.Now()},
		{ID: "guard", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "vllm_mlx", SerialNumber: "SER-G", AccountID: "acct-2", RegisteredAt: time.Now(), LastSeen: time.Now()},
	} {
		if err := s.UpsertProvider(ctx, rec); err != nil {
			t.Fatalf("UpsertProvider(%s): %v", rec.ID, err)
		}
	}
	// A reputation row for "a" — without the FK-ordered delete, removing the
	// provider would fail.
	if err := s.UpsertReputation(ctx, "a", ReputationRecord{TotalJobs: 7}); err != nil {
		t.Fatalf("UpsertReputation: %v", err)
	}
	// An earnings row (money history) that MUST survive the delete.
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID: "acct-1", ProviderID: "a", ProviderKey: "key-a",
		JobID: "j1", Model: "m", AmountMicroUSD: 123_000, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("RecordProviderEarning: %v", err)
	}

	n, err := s.DeleteProvidersBySerial(ctx, "acct-1", "SER")
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if n != 1 {
		t.Fatalf("rows_removed = %d, want 1", n)
	}

	if rec, _ := s.GetProviderBySerial(ctx, "SER"); rec != nil {
		t.Fatal("provider row still present after delete")
	}
	if rep, _ := s.GetReputation(ctx, "a"); rep != nil {
		t.Fatal("reputation row still present after delete")
	}
	// Earnings (money history) must survive.
	earnings, err := s.GetProviderEarnings("key-a", 10)
	if err != nil {
		t.Fatalf("GetProviderEarnings: %v", err)
	}
	if len(earnings) != 1 {
		t.Fatalf("earnings count = %d, want 1 (money history must survive)", len(earnings))
	}
	// Cross-account guard row must survive.
	if rec, _ := s.GetProviderBySerial(ctx, "SER-G"); rec == nil {
		t.Fatal("cross-account guard row was deleted")
	}
}

// TestPostgresDeleteProvidersBySerial_WrongOwner verifies a non-owner delete is
// a no-op even when the serial matches.
func TestPostgresDeleteProvidersBySerial_WrongOwner(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	if err := s.UpsertProvider(ctx, ProviderRecord{ID: "a", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "vllm_mlx", SerialNumber: "SER", AccountID: "acct-1", RegisteredAt: time.Now(), LastSeen: time.Now()}); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}

	n, err := s.DeleteProvidersBySerial(ctx, "acct-2", "SER")
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if n != 0 {
		t.Fatalf("rows_removed = %d, want 0 for non-owner", n)
	}
	if rec, _ := s.GetProviderBySerial(ctx, "SER"); rec == nil {
		t.Fatal("record deleted by non-owner")
	}
}

func TestPostgresCreateStripeWithdrawalWithDebit(t *testing.T) {
	s := testPostgresStore(t)
	u := &User{AccountID: "acct-pg-wdb", PrivyUserID: "did:privy:pgwdb"}
	_ = s.CreateUser(u)
	if err := s.CreditWithdrawable("acct-pg-wdb", 10_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}

	wd := &StripeWithdrawal{
		ID: "wd-pg-atomic-1", AccountID: "acct-pg-wdb", StripeAccountID: "acct_pgwdb",
		AmountMicroUSD: 4_000_000, NetMicroUSD: 4_000_000,
		Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(wd, LedgerStripePayout, "stripe_withdraw:wd-pg-atomic-1"); err != nil {
		t.Fatalf("atomic debit+insert: %v", err)
	}
	bal, wdr := s.GetBalanceWithWithdrawable("acct-pg-wdb")
	if bal != 6_000_000 || wdr != 6_000_000 {
		t.Errorf("balance/withdrawable = %d/%d, want 6_000_000/6_000_000", bal, wdr)
	}
	row, err := s.GetStripeWithdrawal("wd-pg-atomic-1")
	if err != nil || row.Status != "pending" {
		t.Fatalf("row = %+v err = %v", row, err)
	}

	// Insufficient withdrawable: typed error, no debit, no row. The whole
	// transaction rolls back — including the ledger entry.
	wd2 := &StripeWithdrawal{
		ID: "wd-pg-atomic-2", AccountID: "acct-pg-wdb", StripeAccountID: "acct_pgwdb",
		AmountMicroUSD: 60_000_000, NetMicroUSD: 60_000_000,
		Method: "standard", Status: "pending",
	}
	err = s.CreateStripeWithdrawalWithDebit(wd2, LedgerStripePayout, "stripe_withdraw:wd-pg-atomic-2")
	if !errors.Is(err, ErrInsufficientBalance) {
		t.Fatalf("err = %v, want ErrInsufficientBalance", err)
	}
	if bal, _ := s.GetBalanceWithWithdrawable("acct-pg-wdb"); bal != 6_000_000 {
		t.Errorf("failed attempt moved the balance: %d", bal)
	}
	if _, err := s.GetStripeWithdrawal("wd-pg-atomic-2"); err == nil {
		t.Error("row must not exist after a failed debit")
	}

	// Duplicate row ID: the insert fails and the tx rolls back the debit.
	dup := &StripeWithdrawal{
		ID: "wd-pg-atomic-1", AccountID: "acct-pg-wdb", StripeAccountID: "acct_pgwdb",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(dup, LedgerStripePayout, "stripe_withdraw:pg-dup"); err == nil {
		t.Fatal("duplicate ID must fail")
	}
	if bal, _ := s.GetBalanceWithWithdrawable("acct-pg-wdb"); bal != 6_000_000 {
		t.Errorf("duplicate attempt leaked a debit: balance = %d", bal)
	}
}

func TestPostgresCreateStripeAutoWithdrawalWithDebit(t *testing.T) {
	s := testPostgresStore(t)
	user := &User{AccountID: "acct-pg-auto-debit", PrivyUserID: "did:privy:pg-auto-debit"}
	if err := s.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(user.AccountID, "acct_pg_auto_debit", "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(user.AccountID, 10_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Truncate(time.Second)
	slot := now.Add(-time.Minute)
	if err := s.SetStripeAutoWithdraw(user.AccountID, "acct_pg_auto_debit", true, now.Add(-time.Hour), slot); err != nil {
		t.Fatal(err)
	}
	newWithdrawal := func(id string) *StripeWithdrawal {
		return &StripeWithdrawal{
			ID: id, AccountID: user.AccountID, StripeAccountID: "acct_pg_auto_debit",
			AmountMicroUSD: 4_000_000, NetMicroUSD: 4_000_000,
			Method: "standard", Status: "pending",
		}
	}

	err := s.CreateStripeAutoWithdrawalWithDebit(
		newWithdrawal("wd-pg-auto-stale"), LedgerStripePayout,
		"stripe_withdraw:wd-pg-auto-stale", slot.Add(-time.Hour),
	)
	if !errors.Is(err, ErrAutoWithdrawNotAuthorized) {
		t.Fatalf("stale slot err = %v, want ErrAutoWithdrawNotAuthorized", err)
	}

	wd := newWithdrawal("wd-pg-auto-ok")
	if err := s.CreateStripeAutoWithdrawalWithDebit(
		wd, LedgerStripePayout, "stripe_withdraw:wd-pg-auto-ok", slot,
	); err != nil {
		t.Fatal(err)
	}
	stored, err := s.GetStripeWithdrawal(wd.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Source != StripeWithdrawalSourceAutomatic || stored.ScheduledFor == nil ||
		!stored.ScheduledFor.Equal(slot) {
		t.Fatalf("automatic metadata = %+v", stored)
	}
	if balance := s.GetWithdrawableBalance(user.AccountID); balance != 6_000_000 {
		t.Fatalf("balance = %d, want 6_000_000", balance)
	}

	rows, err := s.ListStripeWithdrawalsBySourceStatusAfter(
		StripeWithdrawalSourceAutomatic, "pending", time.Now().Add(-time.Hour), 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, row := range rows {
		if row.ID == wd.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("pending automatic rows did not include %s: %+v", wd.ID, rows)
	}
}

func TestPostgresStripeWithdrawalAtomicFailureAndGuards(t *testing.T) {
	s := testPostgresStore(t)
	accountID := "acct-pg-auto-guards"
	if err := s.CreditWithdrawable(accountID, 5_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}
	wd := &StripeWithdrawal{
		ID: "wd-pg-auto-guards", AccountID: accountID, StripeAccountID: "acct_pg_guards",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Source: StripeWithdrawalSourceAutomatic, Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(
		wd, LedgerStripePayout, "stripe_withdraw:"+wd.ID,
	); err != nil {
		t.Fatal(err)
	}
	if applied, err := s.RecordStripeWithdrawalPendingFailure(wd.ID, "timeout"); err != nil || !applied {
		t.Fatalf("pending failure = %v, err = %v", applied, err)
	}
	if applied, err := s.MarkStripeWithdrawalTransferred(wd.ID, "tr_pg_guards"); err != nil || !applied {
		t.Fatalf("mark transferred = %v, err = %v", applied, err)
	}
	if applied, err := s.RecordStripeWithdrawalPendingFailure(wd.ID, "stale"); err != nil || applied {
		t.Fatalf("stale pending failure = %v, err = %v", applied, err)
	}
	stored, _ := s.GetStripeWithdrawal(wd.ID)
	if stored.Status != "transferred" || stored.TransferID != "tr_pg_guards" ||
		stored.FailureReason != "" {
		t.Fatalf("stale worker overwrote transfer: %+v", stored)
	}

	refundWD := &StripeWithdrawal{
		ID: "wd-pg-auto-refund", AccountID: accountID, StripeAccountID: "acct_pg_guards",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Source: StripeWithdrawalSourceAutomatic, Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(
		refundWD, LedgerStripePayout, "stripe_withdraw:"+refundWD.ID,
	); err != nil {
		t.Fatal(err)
	}
	if refunded, err := s.FailStripeWithdrawalAndRefund(refundWD.ID, "definitive failure"); err != nil || !refunded {
		t.Fatalf("atomic refund = %v, err = %v", refunded, err)
	}
	if refunded, err := s.FailStripeWithdrawalAndRefund(refundWD.ID, "redelivery"); err != nil || !refunded {
		t.Fatalf("idempotent refund = %v, err = %v", refunded, err)
	}
	refundedRow, _ := s.GetStripeWithdrawal(refundWD.ID)
	if refundedRow.Status != "failed" || !refundedRow.Refunded {
		t.Fatalf("refunded row = %+v", refundedRow)
	}
}

func TestPostgresStripeWithdrawalExecutionLock(t *testing.T) {
	s := testPostgresStore(t)
	acquired, release, err := s.TryLockStripeWithdrawal("wd-pg-lock")
	if err != nil || !acquired {
		t.Fatalf("first lock = %v, err = %v", acquired, err)
	}
	if acquired, _, err := s.TryLockStripeWithdrawal("wd-pg-lock"); err != nil || acquired {
		t.Fatalf("second lock = %v, err = %v", acquired, err)
	}
	release()
	acquired, release, err = s.TryLockStripeWithdrawal("wd-pg-lock")
	if err != nil || !acquired {
		t.Fatalf("lock after release = %v, err = %v", acquired, err)
	}
	release()
}
