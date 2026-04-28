package store

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// testPostgresStore returns a PostgresStore connected to the test database.
// It skips the test if DATABASE_URL is not set.
// Each test gets a clean slate by truncating all tables.
func testPostgresStore(t *testing.T) *PostgresStore {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s, err := NewPostgres(ctx, dbURL)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}

	// Clean tables for test isolation.
	for _, table := range []string{
		"usage",
		"payments",
		"api_keys",
		"balances",
		"ledger_entries",
		"billing_sessions",
		"users",
		"device_codes",
		"provider_tokens",
		"invite_redemptions",
		"invite_codes",
		"referrals",
		"referrers",
		"provider_earnings",
		"provider_payouts",
		"providers",
		"stripe_withdrawals",
	} {
		if _, err := s.pool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}

	t.Cleanup(func() { s.Close() })
	return s
}

func TestPostgresCreateKey(t *testing.T) {
	s := testPostgresStore(t)

	key, err := s.CreateKey()
	if err != nil {
		t.Fatalf("CreateKey: %v", err)
	}

	if !strings.HasPrefix(key, "darkbloom-") {
		t.Errorf("key %q does not have darkbloom- prefix", key)
	}

	if !s.ValidateKey(key) {
		t.Error("created key should be valid")
	}

	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestPostgresCreateMultipleKeys(t *testing.T) {
	s := testPostgresStore(t)

	key1, _ := s.CreateKey()
	key2, _ := s.CreateKey()

	if key1 == key2 {
		t.Error("keys should be unique")
	}

	if s.KeyCount() != 2 {
		t.Errorf("key count = %d, want 2", s.KeyCount())
	}
}

func TestPostgresValidateKeyInvalid(t *testing.T) {
	s := testPostgresStore(t)

	if s.ValidateKey("wrong-key") {
		t.Error("wrong key should not be valid")
	}
	if s.ValidateKey("") {
		t.Error("empty key should not be valid")
	}
}

func TestPostgresRevokeKey(t *testing.T) {
	s := testPostgresStore(t)

	key, _ := s.CreateKey()
	if !s.ValidateKey(key) {
		t.Fatal("key should be valid before revoke")
	}

	if !s.RevokeKey(key) {
		t.Error("RevokeKey should return true for existing key")
	}
	if s.ValidateKey(key) {
		t.Error("key should be invalid after revoke")
	}
	if s.KeyCount() != 0 {
		t.Errorf("key count = %d, want 0 after revoke", s.KeyCount())
	}
}

func TestPostgresRevokeKeyNonexistent(t *testing.T) {
	s := testPostgresStore(t)

	if s.RevokeKey("nonexistent") {
		t.Error("RevokeKey should return false for nonexistent key")
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

func TestPostgresRecordUsage(t *testing.T) {
	s := testPostgresStore(t)

	s.RecordUsage("provider-1", "consumer-key", "qwen3.5-9b", 50, 100)
	s.RecordUsage("provider-2", "consumer-key", "llama-3", 30, 200)

	records := s.UsageRecords()
	if len(records) != 2 {
		t.Fatalf("usage records = %d, want 2", len(records))
	}

	r := records[0]
	if r.ProviderID != "provider-1" {
		t.Errorf("provider_id = %q", r.ProviderID)
	}
	if r.Model != "qwen3.5-9b" {
		t.Errorf("model = %q", r.Model)
	}
	if r.PromptTokens != 50 {
		t.Errorf("prompt_tokens = %d", r.PromptTokens)
	}
	if r.CompletionTokens != 100 {
		t.Errorf("completion_tokens = %d", r.CompletionTokens)
	}
	if r.Timestamp.IsZero() {
		t.Error("timestamp should not be zero")
	}
}

func TestPostgresUsageRecordsEmpty(t *testing.T) {
	s := testPostgresStore(t)

	records := s.UsageRecords()
	if len(records) != 0 {
		t.Errorf("usage records = %d, want 0", len(records))
	}
}

func TestPostgresRecordPayment(t *testing.T) {
	s := testPostgresStore(t)

	err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "test payment")
	if err != nil {
		t.Fatalf("RecordPayment: %v", err)
	}
}

func TestPostgresRecordPaymentDuplicateTxHash(t *testing.T) {
	s := testPostgresStore(t)

	err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
	if err != nil {
		t.Fatalf("first RecordPayment: %v", err)
	}

	err = s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
	if err == nil {
		t.Error("expected error for duplicate tx_hash")
	}
}

func TestPostgresProviderPayoutsPersist(t *testing.T) {
	s := testPostgresStore(t)

	payout := &ProviderPayout{
		ProviderAddress: "0xprovider-wallet",
		AmountMicroUSD:  900_000,
		Model:           "qwen3.5-9b",
		JobID:           "job-123",
	}
	if err := s.RecordProviderPayout(payout); err != nil {
		t.Fatalf("RecordProviderPayout: %v", err)
	}

	payouts, err := s.ListProviderPayouts()
	if err != nil {
		t.Fatalf("ListProviderPayouts: %v", err)
	}
	if len(payouts) != 1 {
		t.Fatalf("provider payouts = %d, want 1", len(payouts))
	}
	if payouts[0].ProviderAddress != payout.ProviderAddress {
		t.Errorf("provider address = %q, want %q", payouts[0].ProviderAddress, payout.ProviderAddress)
	}
	if payouts[0].Settled {
		t.Fatal("provider payout should start unsettled")
	}

	if err := s.SettleProviderPayout(payouts[0].ID); err != nil {
		t.Fatalf("SettleProviderPayout: %v", err)
	}

	payouts, err = s.ListProviderPayouts()
	if err != nil {
		t.Fatalf("ListProviderPayouts after settle: %v", err)
	}
	if !payouts[0].Settled {
		t.Fatal("provider payout should be settled")
	}
}

func TestPostgresCreditProviderAccountAtomic(t *testing.T) {
	s := testPostgresStore(t)

	earning := &ProviderEarning{
		AccountID:        "acct-linked",
		ProviderID:       "provider-1",
		ProviderKey:      "key-1",
		JobID:            "job-atomic",
		Model:            "qwen3.5-9b",
		AmountMicroUSD:   123_000,
		PromptTokens:     10,
		CompletionTokens: 20,
	}
	if err := s.CreditProviderAccount(earning); err != nil {
		t.Fatalf("CreditProviderAccount: %v", err)
	}

	if bal := s.GetBalance("acct-linked"); bal != 123_000 {
		t.Fatalf("balance = %d, want 123000", bal)
	}

	history := s.LedgerHistory("acct-linked")
	if len(history) != 1 {
		t.Fatalf("ledger history = %d, want 1", len(history))
	}
	if history[0].Type != LedgerPayout {
		t.Fatalf("ledger entry type = %q, want payout", history[0].Type)
	}

	earnings, err := s.GetAccountEarnings("acct-linked", 10)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 1 {
		t.Fatalf("earnings = %d, want 1", len(earnings))
	}
	if earnings[0].JobID != "job-atomic" {
		t.Fatalf("earning job_id = %q, want job-atomic", earnings[0].JobID)
	}
}

func TestPostgresCreditProviderWalletAtomic(t *testing.T) {
	s := testPostgresStore(t)

	payout := &ProviderPayout{
		ProviderAddress: "0xatomicwallet",
		AmountMicroUSD:  456_000,
		Model:           "llama-3",
		JobID:           "job-wallet",
	}
	if err := s.CreditProviderWallet(payout); err != nil {
		t.Fatalf("CreditProviderWallet: %v", err)
	}

	if bal := s.GetBalance("0xatomicwallet"); bal != 456_000 {
		t.Fatalf("wallet balance = %d, want 456000", bal)
	}

	history := s.LedgerHistory("0xatomicwallet")
	if len(history) != 1 {
		t.Fatalf("ledger history = %d, want 1", len(history))
	}
	if history[0].Type != LedgerPayout {
		t.Fatalf("ledger entry type = %q, want payout", history[0].Type)
	}

	payouts, err := s.ListProviderPayouts()
	if err != nil {
		t.Fatalf("ListProviderPayouts: %v", err)
	}
	if len(payouts) != 1 {
		t.Fatalf("provider payouts = %d, want 1", len(payouts))
	}
	if payouts[0].JobID != "job-wallet" {
		t.Fatalf("payout job_id = %q, want job-wallet", payouts[0].JobID)
	}
}

func TestPostgresStoreImplementsInterface(t *testing.T) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s, err := NewPostgres(ctx, dbURL)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	defer s.Close()

	var _ Store = s
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

	if err := s.SetUserStripeAccount("acct-pg-1", "acct_123", "ready", "card", "4242", true); err != nil {
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
	if got.StripeDestinationType != "card" || got.StripeDestinationLast4 != "4242" {
		t.Errorf("destination = %q ••%q", got.StripeDestinationType, got.StripeDestinationLast4)
	}
	if !got.StripeInstantEligible {
		t.Error("instant_eligible should be true")
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

func TestPostgresSetUserStripeAccountUserNotFound(t *testing.T) {
	s := testPostgresStore(t)
	err := s.SetUserStripeAccount("nope", "acct_x", "pending", "", "", false)
	if err == nil {
		t.Fatal("expected error for missing user")
	}
}

func TestPostgresStripeWithdrawalCRUD(t *testing.T) {
	s := testPostgresStore(t)

	u := &User{AccountID: "acct-pg-wd", PrivyUserID: "did:privy:pgwd"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-wd", "acct_wd", "ready", "bank", "6789", false)

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
	_ = s.SetUserStripeAccount("acct-pg-rf", "acct_rf", "ready", "bank", "1", false)

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
	_ = s.SetUserStripeAccount("acct-pg-dup", "acct_dup", "ready", "bank", "1", false)

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
