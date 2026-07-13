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

	if _, err := ApplyPostgresMigrations(ctx, dbURL, MigrationOptions{}); err != nil {
		t.Fatalf("ApplyPostgresMigrations: %v", err)
	}
	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	pinDefaultPostgresSchema(cfg.ConnConfig.RuntimeParams)
	cfg.MaxConns = maxConns
	cfg.MinConns = 0

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	s := &PostgresStore{pool: pool}
	if err := checkSchemaCompatibility(ctx, pool); err != nil {
		pool.Close()
		t.Fatalf("check schema compatibility: %v", err)
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

	// Re-adopt the legacy schema with the marker cleared. The guarded cleanup
	// executes exactly once while version 1 is recorded.
	reapplyLegacyBaselineForTest(t, s)

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
// gated behind its schema_migrations marker and does NOT run on every migration
// invocation. Once marked, even a legacy-baseline replay leaves later orphan
// wallet-keyed rows untouched.
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

	reapplyLegacyBaselineForTest(t, s)

	if _, _, ok := s.GetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b"); !ok {
		t.Error("orphan row should survive when the cleanup marker is already set (run-once)")
	}
}

func reapplyLegacyBaselineForTest(t *testing.T, s *PostgresStore) {
	t.Helper()
	ctx := context.Background()
	catalog, err := loadMigrations()
	if err != nil {
		t.Fatalf("load legacy baseline migration: %v", err)
	}
	statements, err := splitSQLStatements(catalog[0].SQL)
	if err != nil {
		t.Fatalf("split legacy baseline migration: %v", err)
	}
	if err := executeMigrationStatements(ctx, s.pool, catalog[0], statements); err != nil {
		t.Fatalf("reapply legacy baseline statements: %v", err)
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

func TestPostgresProviderTokenRevokeAndOwnerDeleteAreLatestSchemaAtomic(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	const (
		revokeRaw    = "provider-token-direct-revoke"
		deleteRaw    = "provider-token-owner-delete"
		legacyRawOne = "provider-token-legacy-owner-one"
		legacyRawTwo = "provider-token-legacy-owner-two"
		providerID   = "10000000-0000-0000-0000-000000000006"
		accountID    = "acct-delete-provider"
		serial       = "SERIAL-DELETE-PROVIDER"
		sePublicKey  = "se-delete-provider"
		providerHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	)
	old := time.Now().Add(-time.Hour)
	if err := s.CreateProviderToken(&ProviderToken{
		TokenHash: hashKey(revokeRaw),
		AccountID: accountID,
		Active:    true,
		UpdatedAt: old,
	}); err != nil {
		t.Fatalf("CreateProviderToken(revoke): %v", err)
	}
	if err := s.RevokeProviderToken(revokeRaw); err != nil {
		t.Fatalf("RevokeProviderToken: %v", err)
	}
	var directActive bool
	var directRevokedAt *time.Time
	var directUpdatedAt time.Time
	if err := s.pool.QueryRow(ctx,
		`SELECT active, revoked_at, updated_at
		 FROM provider_tokens WHERE token_hash = $1`,
		hashKey(revokeRaw),
	).Scan(&directActive, &directRevokedAt, &directUpdatedAt); err != nil {
		t.Fatalf("read directly revoked token: %v", err)
	}
	if directActive || directRevokedAt == nil || !directUpdatedAt.After(old) {
		t.Fatalf(
			"direct revoke state = active:%v revoked:%v updated:%s",
			directActive, directRevokedAt, directUpdatedAt,
		)
	}

	deleteHash := hashKey(deleteRaw)
	if err := s.CreateProviderToken(&ProviderToken{
		TokenHash:  deleteHash,
		AccountID:  accountID,
		ProviderID: providerID,
		Active:     true,
	}); err != nil {
		t.Fatalf("CreateProviderToken(delete): %v", err)
	}
	for _, legacyRaw := range []string{legacyRawOne, legacyRawTwo} {
		if err := s.CreateProviderToken(&ProviderToken{
			TokenHash: hashKey(legacyRaw),
			AccountID: accountID,
			Active:    true,
		}); err != nil {
			t.Fatalf("CreateProviderToken(%q): %v", legacyRaw, err)
		}
		if _, err := s.GetProviderToken(legacyRaw); err != nil {
			t.Fatalf("legacy token %q did not authenticate before delete: %v", legacyRaw, err)
		}
	}
	if err := s.UpsertProvider(ctx, ProviderRecord{
		ID:           providerID,
		Hardware:     json.RawMessage(`{}`),
		Models:       json.RawMessage(`[]`),
		Backend:      "mlx",
		SerialNumber: serial,
		SEPublicKey:  sePublicKey,
		AccountID:    accountID,
		TokenHash:    deleteHash,
		RegisteredAt: time.Now(),
		LastSeen:     time.Now(),
	}); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}
	now := time.Now()
	if err := s.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{
		SEPubKey:       sePublicKey,
		ProviderID:     providerID,
		Serial:         serial,
		TrustLevel:     "hardware",
		BinaryHash:     providerHash,
		SIPEnabled:     true,
		SecureBootFull: true,
		MDAUDID:        "UDID-DELETE-PROVIDER",
		Enrolled:       true,
		SecurityInfoAt: &now,
		VerifiedAt:     now,
	}); err != nil {
		t.Fatalf("UpsertProviderTrustReuse: %v", err)
	}

	rows, err := s.DeleteProvidersBySerial(ctx, accountID, serial)
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if rows != 1 {
		t.Fatalf("rows_removed = %d, want 1", rows)
	}
	var deletedActive bool
	var deletedRevokedAt *time.Time
	if err := s.pool.QueryRow(ctx,
		`SELECT active, revoked_at
		 FROM provider_tokens WHERE token_hash = $1`,
		deleteHash,
	).Scan(&deletedActive, &deletedRevokedAt); err != nil {
		t.Fatalf("read owner-deleted token: %v", err)
	}
	if deletedActive || deletedRevokedAt == nil {
		t.Fatalf("owner-deleted token = active:%v revoked:%v", deletedActive, deletedRevokedAt)
	}
	if _, err := s.GetProviderToken(deleteRaw); err == nil {
		t.Fatal("owner-deleted provider token reauthenticated")
	}
	for _, legacyRaw := range []string{legacyRawOne, legacyRawTwo} {
		if _, err := s.GetProviderToken(legacyRaw); err == nil {
			t.Fatalf("legacy-unlinked provider token %q reauthenticated after owner delete", legacyRaw)
		}
	}
	var activeLegacy, revokedLegacy int
	if err := s.pool.QueryRow(ctx,
		`SELECT
		    COUNT(*) FILTER (WHERE active),
		    COUNT(*) FILTER (
		        WHERE NOT active AND revoked_at IS NOT NULL
		          AND updated_at >= revoked_at
		    )
		 FROM provider_tokens
		 WHERE token_hash = ANY($1)`,
		[]string{hashKey(legacyRawOne), hashKey(legacyRawTwo)},
	).Scan(&activeLegacy, &revokedLegacy); err != nil {
		t.Fatalf("read legacy token revocation state: %v", err)
	}
	if activeLegacy != 0 || revokedLegacy != 2 {
		t.Fatalf("legacy token state = active:%d revoked:%d, want 0/2", activeLegacy, revokedLegacy)
	}
	var providerCount, reuseCount, hardFenceCount int
	if err := s.pool.QueryRow(ctx,
		`SELECT
		    (SELECT COUNT(*) FROM providers WHERE id = $1),
		    (SELECT COUNT(*) FROM provider_trust_reuse WHERE provider_id = $1),
		    (SELECT COUNT(*) FROM rust_coord.provider_hard_untrust_epochs
		     WHERE provider_id = $1::UUID)`,
		providerID,
	).Scan(&providerCount, &reuseCount, &hardFenceCount); err != nil {
		t.Fatalf("read owner-delete state: %v", err)
	}
	if providerCount != 0 || reuseCount != 0 || hardFenceCount != 1 {
		t.Fatalf(
			"owner-delete state = providers:%d reuse:%d hard-fence:%d",
			providerCount, reuseCount, hardFenceCount,
		)
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
