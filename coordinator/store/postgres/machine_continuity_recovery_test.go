package postgres

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInventoryBackfillExcludesRecentAndOpenProviderSessions(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	for _, entry := range []struct {
		id   string
		seen time.Time
		open bool
	}{
		{"recent", now, false}, {"open", now.Add(-10 * time.Minute), true},
		{"historical", now.Add(-10 * time.Minute), false},
	} {
		if err := s.UpsertProvider(ctx, store.ProviderRecord{ID: entry.id, AccountID: "owner", LastSeen: entry.seen, Hardware: []byte(`{}`), Models: []byte(`[]`)}); err != nil {
			t.Fatal(err)
		}
		if entry.open {
			if err := s.OpenProviderSession(ctx, entry.id, "", "owner"); err != nil {
				t.Fatal(err)
			}
		}
	}
	n, err := s.BackfillMachineInventory(ctx, 100)
	if err != nil || n != 1 {
		t.Fatalf("backfill selected live/recent provider: %d %v", n, err)
	}
	if r := readInventorySession(t, s, "historical"); !r.closed || r.observation.Source != "historical_registration" {
		t.Fatalf("historical provider not backfilled: %+v", r)
	}
	for _, id := range []string{"recent", "open"} {
		var exists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM darkbloom_machine_sessions WHERE session_id=$1)`, id).Scan(&exists); err != nil || exists {
			t.Fatalf("%s received a false tombstone: %v %v", id, exists, err)
		}
	}
}
