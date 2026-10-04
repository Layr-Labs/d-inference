package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresSeedKey(t *testing.T) {
	s := testPostgresStore(t)

	err := s.SeedKey("my-admin-key")
	if err != nil {
		t.Fatalf("SeedKey: %v", err)
	}

	if !keyAuthenticates(s, "my-admin-key") {
		t.Error("seeded key should be valid")
	}

	// Seeding the same key again should be a no-op.
	err = s.SeedKey("my-admin-key")
	if err != nil {
		t.Fatalf("SeedKey (duplicate): %v", err)
	}

	if n := activeKeyCount(t, s, ""); n != 1 {
		t.Errorf("key count = %d, want 1", n)
	}
}

func TestPostgresProviderRecordStatsPersisted(t *testing.T) {
	s := testPostgresStore(t)

	rec := store.ProviderRecord{
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

func TestPostgresSetUserStripeAccount(t *testing.T) {
	s := testPostgresStore(t)

	u := &store.User{AccountID: "acct-pg-1", PrivyUserID: "did:privy:pg1", Email: "a@b"}
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
	u := &store.User{
		AccountID:          "acct-pg-svc",
		PrivyUserID:        "did:privy:pgsvc",
		Email:              "svc@b",
		Role:               store.RoleService,
		PlatformFeePercent: &zero,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("create user: %v", err)
	}

	got, err := s.GetUserByAccountID("acct-pg-svc")
	if err != nil {
		t.Fatalf("get user: %v", err)
	}
	if got.Role != store.RoleService {
		t.Errorf("role = %q, want %q (dropped on insert)", got.Role, store.RoleService)
	}
	if got.PlatformFeePercent == nil || *got.PlatformFeePercent != 0 {
		t.Errorf("platform_fee_percent = %v, want 0 (dropped on insert)", got.PlatformFeePercent)
	}

	// A plain user still round-trips with no role and a nil fee override.
	if err := s.CreateUser(&store.User{AccountID: "acct-pg-plain", PrivyUserID: "did:privy:pgplain", Email: "p@b"}); err != nil {
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

	u := &store.User{AccountID: "acct-pg-wd", PrivyUserID: "did:privy:pgwd"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-wd", "acct_wd", "ready", "", "bank", "6789", false)

	wd := &store.StripeWithdrawal{
		ID:              "wd-pg-1",
		AccountID:       "acct-pg-wd",
		StripeAccountID: "acct_wd",
		AmountMicroUSD:  5_000_000,
		FeeMicroUSD:     0,
		NetMicroUSD:     5_000_000,
		Method:          "standard",
		Status:          "pending",
	}
	seedStripeWithdrawal(t, s, wd)

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
	if _, err := s.GetStripeWithdrawalByPayoutID("po_pg_missing"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("missing payout lookup err = %v, want ErrNotFound", err)
	}
	if _, err := s.GetStripeWithdrawalByTransferID("tr_pg_missing"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("missing transfer lookup err = %v, want ErrNotFound", err)
	}

	// Reference-idempotent refund credit: second call with the same
	// (account, type, reference) is skipped.
	applied, err := s.CreditWithdrawableOnce("acct-pg-wd", 500_000, store.LedgerRefund, "stripe_withdraw_fee:wd-pg-1")
	if err != nil || !applied {
		t.Fatalf("first CreditWithdrawableOnce: applied=%v err=%v", applied, err)
	}
	applied, err = s.CreditWithdrawableOnce("acct-pg-wd", 500_000, store.LedgerRefund, "stripe_withdraw_fee:wd-pg-1")
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
	u := &store.User{AccountID: "acct-pg-rf", PrivyUserID: "did:privy:pgrf"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-rf", "acct_rf", "ready", "", "bank", "1", false)

	wd := &store.StripeWithdrawal{
		ID: "wd-pg-rf", AccountID: "acct-pg-rf", StripeAccountID: "acct_rf",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", PayoutID: "po_rf",
	}
	seedStripeWithdrawal(t, s, wd)

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
	u := &store.User{AccountID: "acct-pg-dup", PrivyUserID: "did:privy:pgdup"}
	_ = s.CreateUser(u)
	_ = s.SetUserStripeAccount("acct-pg-dup", "acct_dup", "ready", "", "bank", "1", false)

	wd := &store.StripeWithdrawal{
		ID: "wd-dup", AccountID: "acct-pg-dup", StripeAccountID: "acct_dup",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000, Method: "standard", Status: "pending",
	}
	// Fund a second debit so the duplicate can only fail on its ID.
	if err := s.CreditWithdrawable("acct-pg-dup", wd.AmountMicroUSD, store.LedgerPayout, "seed-extra:wd-dup"); err != nil {
		t.Fatalf("seed: %v", err)
	}
	seedStripeWithdrawal(t, s, wd)
	if err := s.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:wd-dup#2"); err == nil {
		t.Fatal("expected duplicate ID to be rejected")
	}
	if bal := s.GetBalance("acct-pg-dup"); bal != wd.AmountMicroUSD {
		t.Errorf("duplicate attempt moved the balance: %d, want %d", bal, wd.AmountMicroUSD)
	}
}

// TestPoolExhaustion_SimulatedLatency reproduces pool acquisition timeouts
// under slow queries by holding both connections until a waiter times out.
// Explicit occupancy avoids relying on pg_sleep workers winning a timing race.
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

	var held []*pgxpool.Conn
	defer func() {
		for _, conn := range held {
			conn.Release()
		}
	}()
	for range cfg.MaxConns {
		conn, err := pool.Acquire(ctx)
		if err != nil {
			t.Fatalf("occupy pool connection: %v", err)
		}
		held = append(held, conn)
	}
	if got := pool.Stat().AcquiredConns(); got != cfg.MaxConns {
		t.Fatalf("acquired connections = %d, want %d", got, cfg.MaxConns)
	}

	canceledBefore := pool.Stat().CanceledAcquireCount()
	qctx, qcancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer qcancel()
	if _, err := pool.Exec(qctx, "SELECT 1"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("query against exhausted pool = %v, want acquisition deadline exceeded", err)
	}
	if got := pool.Stat().CanceledAcquireCount(); got != canceledBefore+1 {
		t.Errorf("canceled acquisitions = %d, want %d", got, canceledBefore+1)
	}

	// A returned connection must serve subsequent work; a timed-out waiter
	// must not leak the pool slot or poison the live database connection.
	held[0].Release()
	held = held[1:]
	var value int
	if err := pool.QueryRow(ctx, "SELECT 1").Scan(&value); err != nil || value != 1 {
		t.Fatalf("query after releasing a connection: value=%d err=%v", value, err)
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
	for _, rec := range []store.ProviderRecord{
		{ID: "a", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "vllm_mlx", SerialNumber: "SER", AccountID: "acct-1", RegisteredAt: time.Now(), LastSeen: time.Now()},
		{ID: "guard", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "vllm_mlx", SerialNumber: "SER-G", AccountID: "acct-2", RegisteredAt: time.Now(), LastSeen: time.Now()},
	} {
		if err := s.UpsertProvider(ctx, rec); err != nil {
			t.Fatalf("UpsertProvider(%s): %v", rec.ID, err)
		}
	}
	// A reputation row for "a" — without the FK-ordered delete, removing the
	// provider would fail.
	if err := s.UpsertReputation(ctx, "a", store.ReputationRecord{TotalJobs: 7}); err != nil {
		t.Fatalf("UpsertReputation: %v", err)
	}
	// An earnings row (money history) that MUST survive the delete.
	if err := s.RecordProviderEarning(&store.ProviderEarning{
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

	if rec, _ := s.GetProviderForRestore(ctx, "SER", "", nil); rec != nil {
		t.Fatal("provider row still present after delete")
	}
	if rep, _ := s.GetReputation(ctx, "a"); rep != nil {
		t.Fatal("reputation row still present after delete")
	}
	// Earnings (money history) must survive.
	earnings, err := s.GetAccountEarnings("acct-1", 10)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 1 || earnings[0].ProviderKey != "key-a" {
		t.Fatalf("earnings count = %d, want 1 (money history must survive)", len(earnings))
	}
	// Cross-account guard row must survive.
	if rec, _ := s.GetProviderForRestore(ctx, "SER-G", "", nil); rec == nil {
		t.Fatal("cross-account guard row was deleted")
	}
}

// TestPostgresDeleteProvidersBySerial_WrongOwner verifies a non-owner delete is
// a no-op even when the serial matches.
func TestPostgresDeleteProvidersBySerial_WrongOwner(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	if err := s.UpsertProvider(ctx, store.ProviderRecord{ID: "a", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), Backend: "vllm_mlx", SerialNumber: "SER", AccountID: "acct-1", RegisteredAt: time.Now(), LastSeen: time.Now()}); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}

	n, err := s.DeleteProvidersBySerial(ctx, "acct-2", "SER")
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if n != 0 {
		t.Fatalf("rows_removed = %d, want 0 for non-owner", n)
	}
	if rec, _ := s.GetProviderForRestore(ctx, "SER", "", nil); rec == nil {
		t.Fatal("record deleted by non-owner")
	}
}

func TestPostgresCreateStripeWithdrawalWithDebit(t *testing.T) {
	s := testPostgresStore(t)
	u := &store.User{AccountID: "acct-pg-wdb", PrivyUserID: "did:privy:pgwdb"}
	_ = s.CreateUser(u)
	if err := s.CreditWithdrawable("acct-pg-wdb", 10_000_000, store.LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}

	wd := &store.StripeWithdrawal{
		ID: "wd-pg-atomic-1", AccountID: "acct-pg-wdb", StripeAccountID: "acct_pgwdb",
		AmountMicroUSD: 4_000_000, NetMicroUSD: 4_000_000,
		Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:wd-pg-atomic-1"); err != nil {
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
	wd2 := &store.StripeWithdrawal{
		ID: "wd-pg-atomic-2", AccountID: "acct-pg-wdb", StripeAccountID: "acct_pgwdb",
		AmountMicroUSD: 60_000_000, NetMicroUSD: 60_000_000,
		Method: "standard", Status: "pending",
	}
	err = s.CreateStripeWithdrawalWithDebit(wd2, store.LedgerStripePayout, "stripe_withdraw:wd-pg-atomic-2")
	if !errors.Is(err, store.ErrInsufficientBalance) {
		t.Fatalf("err = %v, want ErrInsufficientBalance", err)
	}
	if bal, _ := s.GetBalanceWithWithdrawable("acct-pg-wdb"); bal != 6_000_000 {
		t.Errorf("failed attempt moved the balance: %d", bal)
	}
	if _, err := s.GetStripeWithdrawal("wd-pg-atomic-2"); err == nil {
		t.Error("row must not exist after a failed debit")
	}

	// Duplicate row ID: the insert fails and the tx rolls back the debit.
	dup := &store.StripeWithdrawal{
		ID: "wd-pg-atomic-1", AccountID: "acct-pg-wdb", StripeAccountID: "acct_pgwdb",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(dup, store.LedgerStripePayout, "stripe_withdraw:pg-dup"); err == nil {
		t.Fatal("duplicate ID must fail")
	}
	if bal, _ := s.GetBalanceWithWithdrawable("acct-pg-wdb"); bal != 6_000_000 {
		t.Errorf("duplicate attempt leaked a debit: balance = %d", bal)
	}
}

// TestFreshDatabaseSchemaServesWithdrawableAndUsageTotals boots NewPostgres on
// an empty database and exercises the two things the retired one-shot
// backfills used to provide there: the balances.withdrawable_micro_usd column
// and the single usage_totals counter row that RecordUsage only UPDATEs.
// Without the row, usage is silently never counted.
func TestFreshDatabaseSchemaServesWithdrawableAndUsageTotals(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres on an empty database: %v", err)
	}
	defer s.Close()

	if err := s.CreditWithdrawable("fresh-acct", 700, store.LedgerPayout, "fresh-ref"); err != nil {
		t.Fatalf("CreditWithdrawable: %v", err)
	}
	if got := s.GetWithdrawableBalance("fresh-acct"); got != 700 {
		t.Fatalf("withdrawable balance = %d, want 700", got)
	}

	s.RecordUsage(store.UsageRecord{ProviderID: "prov", ConsumerKey: "consumer", Model: "model", PromptTokens: 11, CompletionTokens: 13})
	totals, err := s.UsageTotals()
	if err != nil {
		t.Fatalf("UsageTotals: %v", err)
	}
	if totals.Requests != 1 || totals.PromptTokens != 11 || totals.CompletionTokens != 13 {
		t.Fatalf("usage totals = %+v, want 1 request / 11 prompt / 13 completion", totals)
	}

	// A second boot on the same database is a no-op for both.
	again, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("second NewPostgres: %v", err)
	}
	defer again.Close()
	if totals, err := again.UsageTotals(); err != nil || totals.Requests != 1 {
		t.Fatalf("usage totals after reboot = %+v, %v; want the counter preserved", totals, err)
	}
}
