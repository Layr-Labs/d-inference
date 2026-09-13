package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestSandboxPayloadRedactionSkipsLockedRowsAndUsesRetentionIndex(t *testing.T) {
	backend := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	now := time.Now().UTC().Truncate(time.Millisecond)
	sandbox := retentionSandbox(t, backend, now)
	first := retentionCommand(t, backend, sandbox, now.Add(-48*time.Hour), SandboxCommandSucceeded, false)
	second := retentionCommand(t, backend, sandbox, now.Add(-47*time.Hour), SandboxCommandSucceeded, false)
	tx, err := backend.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var id string
	if err := tx.QueryRow(ctx, `SELECT id::text FROM sandbox_commands WHERE id=$1 FOR UPDATE`, first.ID).Scan(&id); err != nil {
		t.Fatal(err)
	}
	bounded, stop := context.WithTimeout(ctx, time.Second)
	defer stop()
	if count, err := backend.RedactSandboxCommandPayloads(bounded, now.Add(-24*time.Hour), now, 1); err != nil || count != 1 {
		t.Fatalf("locked head blocked redaction: count=%d err=%v", count, err)
	}
	unchanged, _ := backend.GetSandboxCommand(ctx, first.AccountID, first.SandboxID, first.ID)
	redacted, _ := backend.GetSandboxCommand(ctx, second.AccountID, second.SandboxID, second.ID)
	if unchanged.PayloadExpired || !redacted.PayloadExpired {
		t.Fatal("redaction did not skip the locked row")
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if count, err := backend.RedactSandboxCommandPayloads(ctx, now.Add(-24*time.Hour), now, 32); err != nil || count != 1 {
		t.Fatalf("unlocked row was not recovered: %d %v", count, err)
	}
	var definition string
	if err := backend.pool.QueryRow(ctx, `SELECT indexdef FROM pg_indexes WHERE schemaname=current_schema() AND indexname='idx_sandbox_commands_payload_retention'`).Scan(&definition); err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"completed_at", "payload_expired", "cancellation_pending"} {
		if !strings.Contains(definition, expected) {
			t.Fatalf("retention index missing %s: %s", expected, definition)
		}
	}
}
