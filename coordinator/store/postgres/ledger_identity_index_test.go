package postgres

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type ledgerIdentityQuery struct {
	sql  string
	args []any
}

type ledgerIdentityTracer struct {
	queries chan ledgerIdentityQuery
}

func (tr *ledgerIdentityTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if strings.Contains(data.SQL, "SELECT EXISTS") && strings.Contains(data.SQL, "FROM ledger_entries") {
		select {
		case tr.queries <- ledgerIdentityQuery{data.SQL, append([]any(nil), data.Args...)}:
		default:
		}
	}
	return ctx
}

func (*ledgerIdentityTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func TestPostgresLedgerOnceLookupUsesAllIdentityColumns(t *testing.T) {
	s := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	const account = "ledger-identity-query-account"
	if _, err := s.pool.Exec(ctx, `INSERT INTO ledger_entries
        (account_id, entry_type, amount_micro_usd, balance_after, reference)
        SELECT $1, 'charge', 1, g, 'history:' || g FROM generate_series(1,6000) g`, account); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `ANALYZE ledger_entries`); err != nil {
		t.Fatal(err)
	}
	tracer := &ledgerIdentityTracer{queries: make(chan ledgerIdentityQuery, 1)}
	cfg := s.pool.Config()
	cfg.ConnConfig.Tracer = tracer
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	writer := &Store{pool: pool}
	if applied, err := writer.CreditOnce(account, 100, contracts.LedgerStripeDeposit, "stripe:point-lookup"); err != nil || !applied {
		t.Fatalf("first deposit applied=%t error=%v", applied, err)
	}
	var lookup ledgerIdentityQuery
	select {
	case lookup = <-tracer.queries:
	default:
		t.Fatal("CreditOnce did not execute its ledger identity lookup")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	for _, setting := range []string{"SET LOCAL enable_seqscan=off", "SET LOCAL enable_bitmapscan=off"} {
		if _, err := tx.Exec(ctx, setting); err != nil {
			t.Fatal(err)
		}
	}
	// Inspect the actual statement captured from CreditOnce. Disabling competing
	// scan strategies tests index applicability, not an incidental cost decision.
	var raw []byte
	if err := tx.QueryRow(ctx, "EXPLAIN (FORMAT JSON) "+lookup.sql, lookup.args...).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	type planNode struct {
		IndexCond string     `json:"Index Cond"`
		Filter    string     `json:"Filter"`
		Plans     []planNode `json:"Plans"`
	}
	var plans []struct{ Plan planNode }
	if err := json.Unmarshal(raw, &plans); err != nil || len(plans) != 1 {
		t.Fatalf("invalid query plan: %s (%v)", raw, err)
	}
	found := false
	var visit func(planNode)
	visit = func(node planNode) {
		if strings.Contains(node.IndexCond, "account_id =") && strings.Contains(node.IndexCond, "entry_type =") && strings.Contains(node.IndexCond, "md5(reference)") && strings.Contains(node.Filter, "reference =") {
			found = true
		}
		for _, child := range node.Plans {
			visit(child)
		}
	}
	visit(plans[0].Plan)
	if !found {
		t.Fatalf("ledger lookup must index account/type/reference digest and retain exact reference equality: %s", raw)
	}
}

func TestPostgresLedgerOnceIndexPreservesLegacyReferences(t *testing.T) {
	s := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	// Recreate the pre-index shape in this owned database, then build the
	// actual startup index over long references and existing duplicate rows.
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_ledger_once_identity`); err != nil {
		t.Fatal(err)
	}
	var note strings.Builder
	for i := range 512 {
		digest := sha256.Sum256([]byte(strconv.Itoa(i)))
		note.WriteString(hex.EncodeToString(digest[:]))
	}
	const account = "legacy-ledger-index-account"
	reference := "admin_credit:" + note.String()
	if err := s.Credit(account, 10, contracts.LedgerAdminCredit, reference); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := s.Credit(account, 100, contracts.LedgerStripeDeposit, "stripe:legacy-duplicate"); err != nil {
			t.Fatal(err)
		}
	}
	var indexOID uint32
	for attempt := range 2 {
		if err := s.ensureConcurrentIndexes(ctx); err != nil {
			t.Fatal(err)
		}
		var oid uint32
		if err := s.pool.QueryRow(ctx, `SELECT 'idx_ledger_once_identity'::regclass::oid`).Scan(&oid); err != nil {
			t.Fatal(err)
		}
		if attempt == 1 && oid != indexOID {
			t.Fatal("repeat startup rebuilt an already valid ledger index")
		}
		indexOID = oid
	}
	for _, identity := range []struct {
		kind contracts.LedgerEntryType
		ref  string
	}{
		{contracts.LedgerAdminCredit, reference},
		{contracts.LedgerStripeDeposit, "stripe:legacy-duplicate"},
	} {
		if applied, err := s.CreditOnce(account, 100, identity.kind, identity.ref); err != nil || applied {
			t.Fatalf("existing %s identity applied=%t error=%v", identity.kind, applied, err)
		}
	}
	if balance, earned := s.GetBalanceWithWithdrawable(account); balance != 210 || earned != 0 {
		t.Fatalf("legacy replay changed balances to(%d,%d), want(210,0)", balance, earned)
	}
	if applied, err := s.CreditOnce(account, 20, contracts.LedgerAdminCredit, reference+":different"); err != nil || !applied {
		t.Fatalf("different long reference applied=%t error=%v", applied, err)
	}
	if balance, earned := s.GetBalanceWithWithdrawable(account); balance != 230 || earned != 0 {
		t.Fatalf("new long-reference credit balances=(%d,%d), want(230,0)", balance, earned)
	}
	if count := len(s.LedgerHistory(account)); count != 4 {
		t.Fatalf("ledger rows=%d, want all three prior rows plus one new credit", count)
	}
}
