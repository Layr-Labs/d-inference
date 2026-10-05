package devnetseed_test

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/command/devnetseed"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func TestParseOptionsRejectsInvalidScale(t *testing.T) {
	for _, args := range [][]string{
		{"--accounts", "0"},
		{"--keys-per-account", "0"},
		{"--sessions-per-provider", "0"},
		{"--workers", "0"},
		{"--providers", "-1"},
		{"--requests-per-account", "-1"},
		{"--balance-micro-usd", "-1"},
		{"--providers", "0"},
		{"extra"},
	} {
		if _, err := devnetseed.ParseOptions(args); err == nil {
			t.Fatalf("invalid options accepted: %v", args)
		}
	}
	if _, err := devnetseed.ParseOptions([]string{"--providers", "0", "--requests-per-account", "0"}); err != nil {
		t.Fatal(err)
	}
}

// Every account keeps the requested consumer balance, and every charge reaches
// a provider owner or the platform, so the balances add up to the remaining
// consumer balances plus the cost of all requests.
func TestSeedConservesBalancesInMemory(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	o, err := devnetseed.ParseOptions([]string{"--accounts", "4", "--providers", "3", "--requests-per-account", "5", "--balance-micro-usd", "1000"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := devnetseed.Seed(context.Background(), st, o); err != nil {
		t.Fatal(err)
	}
	user, err := st.GetUserByEmail("seed-3@example.invalid")
	if err != nil || user.PrivyUserID != "did:privy:seed-3" {
		t.Fatalf("seeded user = %+v, %v", user, err)
	}
	usage := st.UsageRecords()
	if len(usage) != 20 {
		t.Fatalf("usage records = %d, want 20", len(usage))
	}
	var charged int64
	for _, rec := range usage {
		charged += rec.CostMicroUSD
	}
	var total int64
	for n := 1; n <= 4; n++ {
		u, err := st.GetUserByEmail(fmt.Sprintf("seed-%d@example.invalid", n))
		if err != nil {
			t.Fatal(err)
		}
		total += st.GetBalance(u.AccountID)
	}
	total += st.GetBalance("platform")
	if charged == 0 || total != 4*1000+charged {
		t.Fatalf("total balance = %d, want %d", total, 4*1000+charged)
	}
}

func TestSeedsEmptyPostgresAndRefusesNonEmpty(t *testing.T) {
	dsn := throwawayDatabase(t)
	t.Setenv("EIGENINFERENCE_DATABASE_URL", dsn)
	ctx := context.Background()
	args := []string{
		"--accounts", "3", "--keys-per-account", "2", "--providers", "2",
		"--sessions-per-provider", "2", "--requests-per-account", "4", "--workers", "2",
	}
	var out bytes.Buffer
	if err := devnetseed.Run(ctx, args, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "seeded 3 accounts, 6 API keys, 2 providers, 4 sessions, 12 requests") {
		t.Fatalf("unexpected output %q", out.String())
	}
	want := map[string]int{
		"SELECT count(*) FROM users WHERE email LIKE 'seed-%@example.invalid'":                            3,
		"SELECT count(*) FROM api_keys":                                                                   6,
		"SELECT count(*) FROM providers WHERE serial_number LIKE 'SEED%'":                                 4,
		"SELECT count(*) FROM provider_sessions WHERE disconnected_at IS NOT NULL AND provider_key <> ''": 4,
		"SELECT count(*) FROM usage":                                                                      12,
		"SELECT count(*) FROM provider_earnings":                                                          12,
		"SELECT count(*) FROM balances":                                                                   3,
		// One deposit per account, then a charge and a provider payout per request.
		"SELECT count(*) FROM ledger_entries": 3 + 12 + 12,
		// Each account keeps the default 5 USD after paying; the charges
		// reached the provider owners.
		"SELECT (SELECT sum(balance_micro_usd) FROM balances) - (SELECT sum(cost_micro_usd) FROM usage)": 3 * 5_000_000,
	}
	assertCounts(t, dsn, want)

	err := devnetseed.Run(ctx, args, &out)
	if err == nil || !strings.Contains(err.Error(), "users table has rows") {
		t.Fatalf("second run error = %v, want refusal", err)
	}
	assertCounts(t, dsn, want)
}

func TestRefusesBeforeMigratingADatabaseWithUsers(t *testing.T) {
	dsn := throwawayDatabase(t)
	t.Setenv("EIGENINFERENCE_DATABASE_URL", dsn)
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, `CREATE TABLE users (account_id TEXT); INSERT INTO users VALUES ('existing')`); err != nil {
		t.Fatal(err)
	}
	if err := devnetseed.Run(ctx, nil, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "refusing") {
		t.Fatalf("run error = %v, want refusal", err)
	}
	var migrated bool
	if err := conn.QueryRow(ctx, `SELECT to_regclass('api_keys') IS NOT NULL`).Scan(&migrated); err != nil {
		t.Fatal(err)
	}
	if migrated {
		t.Fatal("migrations ran against a database that already has users")
	}
}

func assertCounts(t *testing.T, dsn string, want map[string]int) {
	t.Helper()
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	for query, n := range want {
		var got int
		if err := conn.QueryRow(ctx, query).Scan(&got); err != nil {
			t.Fatalf("%s: %v", query, err)
		}
		if got != n {
			t.Errorf("%s = %d, want %d", query, got, n)
		}
	}
}

// throwawayDatabase gives the test its own database on the DATABASE_URL
// server; go test ./... runs store tests that truncate the shared one.
func throwawayDatabase(t *testing.T) string {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("disposable DATABASE_URL required")
	}
	ctx := context.Background()
	u, err := url.Parse(dsn)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		t.Fatal("DATABASE_URL must be a PostgreSQL URL")
	}
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	name := "devnet_seed_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	quoted := pgx.Identifier{name}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quoted+" TEMPLATE template0"); err != nil {
		admin.Close(ctx)
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(ctx, "DROP DATABASE "+quoted+" WITH (FORCE)"); err != nil {
			t.Error(err)
		}
		admin.Close(ctx)
	})
	u.Path = "/" + name
	return u.String()
}
