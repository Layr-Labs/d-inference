package postgres

import (
	"context"
	"fmt"
	"testing"
	"time"
)

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
