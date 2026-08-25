package store

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresAccountingReadersPropagateQueryErrors(t *testing.T) {
	s := testPostgresStore(t)
	s.pool.Close()

	assertError := func(name string, err error) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s returned nil error after pool close", name)
		}
	}

	_, err := s.GetBalance("acct")
	assertError("GetBalance", err)
	_, err = s.GetWithdrawableBalance("acct")
	assertError("GetWithdrawableBalance", err)
	_, _, err = s.GetBalanceWithWithdrawable("acct")
	assertError("GetBalanceWithWithdrawable", err)
	_, err = s.LedgerHistory("acct")
	assertError("LedgerHistory", err)
	_, err = s.GetProviderEarnings("provider-key", 10)
	assertError("GetProviderEarnings", err)
	_, err = s.GetAccountEarnings("acct", 10)
	assertError("GetAccountEarnings", err)
	_, err = s.GetAccountEarningsPage("acct", 10, nil)
	assertError("GetAccountEarningsPage", err)
	_, err = s.GetAccountEarningsWindows(
		"acct",
		time.Now().Add(-24*time.Hour),
		time.Now().Add(-7*24*time.Hour),
	)
	assertError("GetAccountEarningsWindows", err)
	_, err = s.ListProviderPayouts()
	assertError("ListProviderPayouts", err)
}

func TestPostgresAccountingReadersPropagateScanErrors(t *testing.T) {
	s := newMalformedAccountingStore(t, []string{
		`CREATE TABLE balances (
			account_id TEXT PRIMARY KEY,
			balance_micro_usd TEXT,
			withdrawable_micro_usd TEXT
		)`,
		`INSERT INTO balances VALUES ('acct', 'not-an-integer', 'also-not-an-integer')`,
		`CREATE TABLE ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT,
			entry_type TEXT,
			amount_micro_usd TEXT,
			balance_after BIGINT,
			reference TEXT,
			created_at TIMESTAMPTZ
		)`,
		`INSERT INTO ledger_entries (
			account_id, entry_type, amount_micro_usd, balance_after, reference, created_at
		) VALUES ('acct', 'payout', 'not-an-integer', 1, 'job', NOW())`,
		`CREATE TABLE provider_earnings (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT,
			provider_id TEXT,
			provider_key TEXT,
			job_id TEXT,
			model TEXT,
			amount_micro_usd TEXT,
			prompt_tokens INTEGER,
			completion_tokens INTEGER,
			created_at TIMESTAMPTZ
		)`,
		`INSERT INTO provider_earnings (
			account_id, provider_id, provider_key, job_id, model,
			amount_micro_usd, prompt_tokens, completion_tokens, created_at
		) VALUES ('acct', 'provider', 'key', 'job', 'model', 'not-an-integer', 1, 1, NOW())`,
		`CREATE TABLE provider_payouts (
			id BIGSERIAL PRIMARY KEY,
			provider_address TEXT,
			amount_micro_usd TEXT,
			model TEXT,
			job_id TEXT,
			settled BOOLEAN,
			created_at TIMESTAMPTZ
		)`,
		`INSERT INTO provider_payouts (
			provider_address, amount_micro_usd, model, job_id, settled, created_at
		) VALUES ('wallet', 'not-an-integer', 'model', 'job', TRUE, NOW())`,
	})

	assertContains := func(name string, err error, fragment string) {
		t.Helper()
		if err == nil || !strings.Contains(err.Error(), fragment) {
			t.Fatalf("%s error = %v, want %q", name, err, fragment)
		}
	}

	_, err := s.GetBalance("acct")
	assertContains("GetBalance", err, "read balance")
	_, err = s.GetWithdrawableBalance("acct")
	assertContains("GetWithdrawableBalance", err, "read withdrawable balance")
	_, _, err = s.GetBalanceWithWithdrawable("acct")
	assertContains("GetBalanceWithWithdrawable", err, "read balances")
	_, err = s.LedgerHistory("acct")
	assertContains("LedgerHistory", err, "scan ledger history")
	_, err = s.GetProviderEarnings("key", 10)
	assertContains("GetProviderEarnings", err, "scan provider earning")
	_, err = s.GetAccountEarnings("acct", 10)
	assertContains("GetAccountEarnings", err, "scan account earning")
	_, err = s.GetAccountEarningsPage("acct", 10, nil)
	assertContains("GetAccountEarningsPage", err, "scan account earnings page")
	_, err = s.ListProviderPayouts()
	assertContains("ListProviderPayouts", err, "scan provider payout")
}

func TestPostgresAccountEarningsRejectsPartialRowsOnIterationError(t *testing.T) {
	s := newMalformedAccountingStore(t, []string{
		`CREATE FUNCTION fail_on_legacy_row(value BIGINT) RETURNS BIGINT
		 LANGUAGE plpgsql AS $$
		 BEGIN
		   IF value = 1 THEN
		     RAISE EXCEPTION 'synthetic stream failure';
		   END IF;
		   RETURN value;
		 END
		 $$`,
		`CREATE VIEW provider_earnings AS
		 SELECT fail_on_legacy_row(n) AS id,
		        'acct'::TEXT AS account_id,
		        'provider'::TEXT AS provider_id,
		        'key'::TEXT AS provider_key,
		        ('job-' || n)::TEXT AS job_id,
		        'model'::TEXT AS model,
		        1::BIGINT AS amount_micro_usd,
		        1::INTEGER AS prompt_tokens,
		        1::INTEGER AS completion_tokens,
		        TIMESTAMPTZ '2026-08-25 00:00:00Z' + n * INTERVAL '1 second' AS created_at
		   FROM generate_series(1, 2) AS n`,
	})

	rows, err := s.GetAccountEarnings("acct", 10)
	if err == nil || !strings.Contains(err.Error(), "iterate account earnings") {
		t.Fatalf("error = %v, want rows.Err propagation", err)
	}
	if rows != nil {
		t.Fatalf("partial rows escaped with iteration error: %+v", rows)
	}

	page, err := s.GetAccountEarningsPage("acct", 10, nil)
	if err == nil || !strings.Contains(err.Error(), "iterate account earnings page") {
		t.Fatalf("page error = %v, want rows.Err propagation", err)
	}
	if page.Earnings != nil || page.Next != nil {
		t.Fatalf("partial page escaped with iteration error: %+v", page)
	}
}

func newMalformedAccountingStore(t *testing.T, statements []string) *PostgresStore {
	t.Helper()
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	admin, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("open postgres admin pool: %v", err)
	}

	schema := fmt.Sprintf("accounting_reader_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		admin.Close()
		t.Fatalf("create schema: %v", err)
	}

	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		admin.Close()
		t.Fatalf("parse postgres config: %v", err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	cfg.MaxConns = 1
	cfg.MinConns = 0
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		admin.Close()
		t.Fatalf("open isolated pool: %v", err)
	}
	for _, statement := range statements {
		if _, err := pool.Exec(ctx, statement); err != nil {
			pool.Close()
			_, _ = admin.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+schema+" CASCADE")
			admin.Close()
			t.Fatalf("create malformed fixture: %v", err)
		}
	}

	t.Cleanup(func() {
		pool.Close()
		_, _ = admin.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+schema+" CASCADE")
		admin.Close()
	})
	return &PostgresStore{pool: pool}
}
