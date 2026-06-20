package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// TestMemoryProviderSessionLifecycle exercises the full open→touch→close→reconcile
// flow on the in-memory store (always runs, no DB required).
func TestMemoryProviderSessionLifecycle(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()

	if err := st.OpenProviderSession(ctx, "sess-1", "", ""); err != nil {
		t.Fatalf("open: %v", err)
	}
	if len(st.providerSessions) != 1 || st.providerSessions[0].SessionID != "sess-1" ||
		st.providerSessions[0].DisconnectedAt != nil {
		t.Fatalf("after open: %+v", st.providerSessions)
	}

	// Touch backfills the empty serial/account/provider_key and advances last_seen.
	ts := time.Now().Add(time.Minute).Truncate(time.Millisecond)
	if err := st.TouchProviderSession(ctx, "sess-1", "SERIAL1", "ACCT1", "PK1", ts); err != nil {
		t.Fatalf("touch: %v", err)
	}
	if s := st.providerSessions[0]; s.SerialNumber != "SERIAL1" || s.AccountID != "ACCT1" || s.ProviderKey != "PK1" || !s.LastSeen.Equal(ts) {
		t.Fatalf("after touch backfill: %+v", s)
	}

	// A later touch must NOT overwrite an already-known serial/account/provider_key.
	if err := st.TouchProviderSession(ctx, "sess-1", "SERIAL2", "ACCT2", "PK2", ts.Add(time.Minute)); err != nil {
		t.Fatalf("touch2: %v", err)
	}
	if s := st.providerSessions[0]; s.SerialNumber != "SERIAL1" || s.AccountID != "ACCT1" || s.ProviderKey != "PK1" {
		t.Fatalf("touch overwrote serial/account/provider_key: %+v", s)
	}

	// Close sets disconnected_at + reason.
	closeAt := ts.Add(2 * time.Minute)
	if err := st.CloseProviderSession(ctx, "sess-1", "disconnect", closeAt); err != nil {
		t.Fatalf("close: %v", err)
	}
	closed := st.providerSessions[0]
	if closed.DisconnectedAt == nil || !closed.DisconnectedAt.Equal(closeAt) || closed.DisconnectReason != "disconnect" {
		t.Fatalf("after close: %+v", closed)
	}

	// Touch on a closed session is a no-op.
	if err := st.TouchProviderSession(ctx, "sess-1", "X", "Y", "Z", closeAt.Add(time.Hour)); err != nil {
		t.Fatalf("touch-closed: %v", err)
	}
	if !st.providerSessions[0].LastSeen.Equal(closed.LastSeen) {
		t.Fatalf("touch on closed session changed last_seen")
	}

	// Reconcile closes any still-open sessions, stamping disconnected_at=last_seen.
	if err := st.OpenProviderSession(ctx, "sess-2", "S2", "A2"); err != nil {
		t.Fatalf("open2: %v", err)
	}
	n, err := st.CloseOpenProviderSessions(ctx, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if n != 1 {
		t.Fatalf("reconcile closed %d, want 1", n)
	}
	var s2 *ProviderSession
	for i := range st.providerSessions {
		if st.providerSessions[i].SessionID == "sess-2" {
			s2 = &st.providerSessions[i]
		}
	}
	if s2 == nil || s2.DisconnectedAt == nil || s2.DisconnectReason != "coordinator_restart" {
		t.Fatalf("reconcile did not close sess-2: %+v", s2)
	}
	if !s2.DisconnectedAt.Equal(s2.LastSeen) {
		t.Fatalf("reconcile should set disconnected_at = last_seen, got %v vs %v", s2.DisconnectedAt, s2.LastSeen)
	}
}

// TestMemoryProviderSessionCloseBeforeOpen is the regression for the async race
// where a fast connect→disconnect runs Close before Open. The result must be a
// single, already-closed row — never a permanently-open one.
func TestMemoryProviderSessionCloseBeforeOpen(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()
	when := time.Now().Truncate(time.Millisecond)

	// Close arrives first (Open's goroutine lost the race).
	if err := st.CloseProviderSession(ctx, "race-1", "disconnect", when); err != nil {
		t.Fatalf("close: %v", err)
	}
	if len(st.providerSessions) != 1 || st.providerSessions[0].DisconnectedAt == nil {
		t.Fatalf("close-before-open must create exactly one closed row: %+v", st.providerSessions)
	}

	// The late Open must neither duplicate nor reopen it.
	if err := st.OpenProviderSession(ctx, "race-1", "S", "A"); err != nil {
		t.Fatalf("late open: %v", err)
	}
	if len(st.providerSessions) != 1 || st.providerSessions[0].DisconnectedAt == nil {
		t.Fatalf("late open must not duplicate/reopen: %+v", st.providerSessions)
	}

	if n, _ := st.CloseOpenProviderSessions(ctx, time.Now().Add(time.Minute)); n != 0 {
		t.Fatalf("no session should be left open after the race, reconcile closed %d", n)
	}
}

// TestMemoryProviderSessionReconcileFencesFreshSessions is the regression for the
// blue-green deploy truncation bug: a session still being touched (fresh
// last_seen) must NOT be closed by a startup reconcile — only genuinely-orphaned
// (stale) sessions are. Mirrors the new-instance-starts-while-old-instance-live
// cutover over a shared DB.
func TestMemoryProviderSessionReconcileFencesFreshSessions(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()
	now := time.Now()

	// A session live on "another instance": opened, and heartbeated to ~now.
	if err := st.OpenProviderSession(ctx, "fresh", "S1", "A1"); err != nil {
		t.Fatalf("open fresh: %v", err)
	}
	if err := st.TouchProviderSession(ctx, "fresh", "S1", "A1", "PK1", now.Add(-10*time.Second)); err != nil {
		t.Fatalf("touch fresh: %v", err)
	}
	// A genuinely-orphaned session: opened, last heartbeat 10 min ago.
	if err := st.OpenProviderSession(ctx, "stale", "S2", "A2"); err != nil {
		t.Fatalf("open stale: %v", err)
	}
	if err := st.TouchProviderSession(ctx, "stale", "S2", "A2", "PK2", now.Add(-10*time.Minute)); err != nil {
		t.Fatalf("touch stale: %v", err)
	}

	// Reconcile with a 3-minute fence (the prod value).
	n, err := st.CloseOpenProviderSessions(ctx, now.Add(-3*time.Minute))
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if n != 1 {
		t.Fatalf("reconcile closed %d, want 1 (only the stale session)", n)
	}
	for i := range st.providerSessions {
		ps := &st.providerSessions[i]
		switch ps.SessionID {
		case "fresh":
			if ps.DisconnectedAt != nil {
				t.Fatalf("FRESH session was wrongly closed by reconcile (blue-green truncation bug)")
			}
		case "stale":
			if ps.DisconnectedAt == nil || ps.DisconnectReason != "coordinator_restart" {
				t.Fatalf("stale orphaned session was not closed: %+v", ps)
			}
		}
	}
}

// TestPostgresProviderSessionCloseBeforeOpen is the same regression against real
// Postgres (the ON CONFLICT upsert path).
func TestPostgresProviderSessionCloseBeforeOpen(t *testing.T) {
	st := testPostgresStore(t)
	ctx := context.Background()
	sid := fmt.Sprintf("race-test-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		_, _ = st.pool.Exec(context.Background(), `DELETE FROM provider_sessions WHERE session_id=$1`, sid)
	})

	if err := st.CloseProviderSession(ctx, sid, "disconnect", time.Now()); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := st.OpenProviderSession(ctx, sid, "S", "A"); err != nil {
		t.Fatalf("late open: %v", err)
	}
	var total, openCount int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*), count(*) FILTER (WHERE disconnected_at IS NULL) FROM provider_sessions WHERE session_id=$1`,
		sid,
	).Scan(&total, &openCount); err != nil {
		t.Fatalf("query: %v", err)
	}
	if total != 1 || openCount != 0 {
		t.Fatalf("close-before-open: total=%d open=%d, want total=1 open=0", total, openCount)
	}
}

// TestPostgresProviderSessionLifecycle mirrors the memory test against a real
// Postgres (skips unless DATABASE_URL points at a throwaway test DB).
func TestPostgresProviderSessionLifecycle(t *testing.T) {
	st := testPostgresStore(t) // t.Skip()s if DATABASE_URL is unset
	ctx := context.Background()
	sid := fmt.Sprintf("sess-test-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		_, _ = st.pool.Exec(context.Background(), `DELETE FROM provider_sessions WHERE session_id=$1`, sid)
	})

	if err := st.OpenProviderSession(ctx, sid, "", ""); err != nil {
		t.Fatalf("open: %v", err)
	}
	ts := time.Now().Add(time.Minute)
	if err := st.TouchProviderSession(ctx, sid, "SER1", "ACC1", "PK1", ts); err != nil {
		t.Fatalf("touch: %v", err)
	}

	var serial, account, providerKey string
	var disc *time.Time
	if err := st.pool.QueryRow(ctx,
		`SELECT serial_number, account_id, provider_key, disconnected_at FROM provider_sessions WHERE session_id=$1`, sid,
	).Scan(&serial, &account, &providerKey, &disc); err != nil {
		t.Fatalf("query after touch: %v", err)
	}
	if serial != "SER1" || account != "ACC1" || providerKey != "PK1" || disc != nil {
		t.Fatalf("after touch: serial=%q account=%q provider_key=%q disc=%v", serial, account, providerKey, disc)
	}

	if err := st.CloseProviderSession(ctx, sid, "disconnect", time.Now()); err != nil {
		t.Fatalf("close: %v", err)
	}
	var reason string
	if err := st.pool.QueryRow(ctx,
		`SELECT disconnected_at, disconnect_reason FROM provider_sessions WHERE session_id=$1`, sid,
	).Scan(&disc, &reason); err != nil {
		t.Fatalf("query after close: %v", err)
	}
	if disc == nil || reason != "disconnect" {
		t.Fatalf("after close: disc=%v reason=%q", disc, reason)
	}
}
