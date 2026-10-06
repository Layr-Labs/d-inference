package postgres_test

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// debitCancelGate delays only the cancellation packet for the observed blocked
// backend. Business SQL, startup, monitoring and other accounts are unchanged.
// pgx asyncClose sends this packet before closing the original connection.
// This makes the late-statement schedule deterministic without a SQL trigger.
type debitCancelGate struct {
	pid       atomic.Uint32
	entered   chan struct{}
	allow     chan struct{}
	enterOnce sync.Once
	allowOnce sync.Once
	expired   atomic.Bool
}

func (g *debitCancelGate) release() { g.allowOnce.Do(func() { close(g.allow) }) }

type debitCancelConn struct {
	net.Conn
	ctx       context.Context
	gate      *debitCancelGate
	closed    chan struct{}
	closeOnce sync.Once
}

func (c *debitCancelConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return c.Conn.Close()
}

func (c *debitCancelConn) Write(b []byte) (int, error) {
	// PG16 uses a 16-byte CancelRequest. Do not record its secret key.
	if len(b) == 16 && binary.BigEndian.Uint32(b[:4]) == 16 &&
		binary.BigEndian.Uint32(b[4:8]) == 80877102 &&
		c.gate.pid.Load() != 0 && binary.BigEndian.Uint32(b[8:12]) == c.gate.pid.Load() {
		c.gate.enterOnce.Do(func() { close(c.gate.entered) })
		timer := time.NewTimer(12 * time.Second)
		defer timer.Stop()
		select {
		case <-c.gate.allow:
		case <-c.ctx.Done():
			c.gate.expired.Store(true)
			return 0, c.ctx.Err()
		case <-c.closed:
			c.gate.expired.Store(true)
			return 0, net.ErrClosed
		case <-timer.C:
			c.gate.expired.Store(true)
			return 0, context.DeadlineExceeded
		}
	}
	return c.Conn.Write(b)
}

func TestPostgresDebitTimeoutDoesNotCommitAfterCancellationDelay(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	gate := &debitCancelGate{entered: make(chan struct{}), allow: make(chan struct{})}
	s, err := newPostgresWithPoolConfig(ctx, store.Config{DatabaseURL: dsn}, func(cfg *pgxpool.Config) {
		dial := cfg.ConnConfig.DialFunc
		cfg.ConnConfig.DialFunc = func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := dial(ctx, network, address)
			if err != nil {
				return nil, err
			}
			return &debitCancelConn{Conn: conn, ctx: ctx, gate: gate, closed: make(chan struct{})}, nil
		}
	})
	if err != nil {
		gate.release()
		t.Fatal(err)
	}
	accountA := fmt.Sprintf("debit-cancel-a-%d", time.Now().UnixNano())
	accountB := accountA + "-control"
	var holder pgx.Tx
	var debitFinished <-chan struct{}
	// Release the packet before pool.Close, which can wait for async cleanup.
	// Fresh cleanup contexts survive test-context cancellation on early failure.
	t.Cleanup(func() {
		gate.release()
		cleanup, stop := context.WithTimeout(context.Background(), 3*time.Second)
		if holder != nil {
			_ = holder.Rollback(cleanup)
		}
		stop()
		if debitFinished != nil {
			select {
			case <-debitFinished:
			case <-time.After(12 * time.Second):
				t.Error("Debit goroutine did not finish during bounded cleanup")
			}
		}
		cleanup, stop = context.WithTimeout(context.Background(), 3*time.Second)
		_, _ = s.pool.Exec(cleanup, "DELETE FROM ledger_entries WHERE account_id = ANY($1)", []string{accountA, accountB})
		_, _ = s.pool.Exec(cleanup, "DELETE FROM balances WHERE account_id = ANY($1)", []string{accountA, accountB})
		stop()
		s.Close()
	})
	for _, account := range []string{accountA, accountB} {
		if err := s.CreditWithdrawable(account, 1000, store.LedgerRefund, "seed"); err != nil {
			t.Fatal(err)
		}
	}
	holder, err = s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var holderPID int
	if err := holder.QueryRow(ctx, "SELECT pg_backend_pid()").Scan(&holderPID); err != nil {
		t.Fatal(err)
	}
	if _, err := holder.Exec(ctx, "SELECT 1 FROM balances WHERE account_id=$1 FOR UPDATE", accountA); err != nil {
		t.Fatal(err)
	}
	type debitResult struct {
		err     error
		elapsed time.Duration
	}
	result := make(chan debitResult, 1)
	finished := make(chan struct{})
	debitFinished = finished
	go func() {
		defer close(finished)
		start := time.Now()
		err := s.Debit(accountA, 100, store.LedgerCharge, "blocked-a")
		result <- debitResult{err: err, elapsed: time.Since(start)}
	}()
	poll := func(timeout time.Duration, description string, check func(context.Context) (bool, error)) {
		t.Helper()
		window, stop := context.WithTimeout(ctx, timeout)
		defer stop()
		for {
			ok, err := check(window)
			if err != nil {
				t.Fatalf("%s: %v", description, err)
			}
			if ok {
				return
			}
			select {
			case <-window.Done():
				t.Fatalf("timed out waiting for %s", description)
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
	var blockedPID uint32
	poll(3*time.Second, "A waiting on the actual row holder", func(ctx context.Context) (bool, error) {
		var pid int
		err := s.pool.QueryRow(ctx, "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)) LIMIT 1", holderPID).Scan(&pid)
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		if err == nil {
			blockedPID = uint32(pid)
			gate.pid.Store(blockedPID)
		}
		return err == nil, err
	})
	// B must succeed while A's row is still held.
	if err := s.Debit(accountB, 100, store.LedgerCharge, "control-b"); err != nil {
		t.Fatalf("unrelated account debit: %v", err)
	}
	select {
	case <-gate.entered:
	case <-time.After(8 * time.Second):
		t.Fatal("matching cancellation packet never entered the gate")
	}
	var outcome debitResult
	select {
	case outcome = <-result:
	case <-time.After(6 * time.Second):
		t.Fatal("Debit did not return while cancellation was delayed")
	}
	if !errors.Is(outcome.err, context.DeadlineExceeded) {
		t.Fatalf("want deadline error, got %v", outcome.err)
	}
	if outcome.elapsed < 4*time.Second || outcome.elapsed > 11*time.Second {
		t.Fatalf("unexpected bounded operation/cleanup duration: %v", outcome.elapsed)
	}
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	holder = nil
	// With cancellation still gated, force the statement to finish. Old code
	// autocommits (idle); the fix leaves an uncommitted transaction instead.
	var backendState string
	poll(3*time.Second, "original statement completing before cancellation", func(ctx context.Context) (bool, error) {
		err := s.pool.QueryRow(ctx, "SELECT state FROM pg_stat_activity WHERE pid=$1", blockedPID).Scan(&backendState)
		return backendState == "idle" || backendState == "idle in transaction", err
	})
	if gate.expired.Load() {
		t.Fatal("cancellation gate expired before the late-statement schedule was established")
	}
	t.Logf("deadline after %v; original backend completed as %q before cancellation", outcome.elapsed, backendState)
	gate.release()
	poll(4*time.Second, "original backend cleanup", func(ctx context.Context) (bool, error) {
		var gone bool
		err := s.pool.QueryRow(ctx, "SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=$1)", blockedPID).Scan(&gone)
		return gone, err
	})
	if gate.expired.Load() {
		t.Fatal("cancellation gate timed out instead of being released by the fixture")
	}
	var timedOutEntries int
	if err := s.pool.QueryRow(ctx, "SELECT count(*) FROM ledger_entries WHERE account_id=$1 AND reference='blocked-a'", accountA).Scan(&timedOutEntries); err != nil {
		t.Fatal(err)
	}
	if timedOutEntries != 0 {
		t.Fatalf("timed-out debit committed after its error: %d blocked-a ledger rows", timedOutEntries)
	}
	check := func(account string, balance int64, count int) {
		t.Helper()
		var got, withdrawable, ledgerSum int64
		var rows int
		if err := s.pool.QueryRow(ctx, "SELECT balance_micro_usd,withdrawable_micro_usd FROM balances WHERE account_id=$1", account).Scan(&got, &withdrawable); err != nil {
			t.Fatal(err)
		}
		if err := s.pool.QueryRow(ctx, "SELECT count(*),COALESCE(sum(amount_micro_usd),0) FROM ledger_entries WHERE account_id=$1", account).Scan(&rows, &ledgerSum); err != nil {
			t.Fatal(err)
		}
		if got != balance || withdrawable != balance || ledgerSum != balance || rows != count {
			t.Fatalf("balance=%d withdrawable=%d ledger sum=%d rows=%d; want %d/%d", got, withdrawable, ledgerSum, rows, balance, count)
		}
	}
	check(accountA, 1000, 1)
	check(accountB, 900, 2)
	if err := s.Debit(accountA, 100, store.LedgerCharge, "recovery-a"); err != nil {
		t.Fatal(err)
	}
	check(accountA, 900, 2)
	if err := s.Debit(accountA, 901, store.LedgerCharge, "insufficient-a"); !errors.Is(err, store.ErrInsufficientBalance) {
		t.Fatalf("insufficient funds: %v", err)
	}
	check(accountA, 900, 2)
}
