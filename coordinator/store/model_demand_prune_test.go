package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// Audit actual DELETE statement sizes and transaction IDs, not implementation
// counters, so a single large DELETE or one transaction around all batches fails.
func modelDemandPruneFixture(t *testing.T, s *PostgresStore, expired, failAfter int) time.Time {
	t.Helper()
	ctx := context.Background()
	cutoff := time.Now().UTC().Truncate(time.Hour).Add(-ModelDemandRetention)
	old := cutoff.Add(-time.Hour)
	_, err := s.pool.Exec(ctx, `INSERT INTO model_demand_hourly
		(hour,model,consumer_hash,requests,completed,capacity_rejected,latency_rejected,timed_out,failed,cancelled,unknown,excluded,http_429)
		SELECT $1,'model-'||(i%2)::text,lpad(i::text,64,'0'),1,1,0,0,0,0,0,0,0,0
		FROM generate_series(0,$2::integer-1) AS i`, old, expired)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO model_demand_hourly
		(hour,model,consumer_hash,requests,completed,capacity_rejected,latency_rejected,timed_out,failed,cancelled,unknown,excluded,http_429)
		VALUES ($1,'boundary',repeat('a',64),1,1,0,0,0,0,0,0,0,0),
		       ($1+interval '1 hour','recent',repeat('b',64),1,1,0,0,0,0,0,0,0,0)`, cutoff)
	if err != nil {
		t.Fatal(err)
	}
	// Compact projections expire individually, but the partially expired cutoff
	// hour must remain intact until the whole hour is outside retention.
	for _, row := range []struct {
		id, model, consumer string
		at                  time.Time
	}{
		{"old-projection", "model-0", strings.Repeat("0", 64), old.Add(5 * time.Minute)},
		{"boundary-projection", "boundary", strings.Repeat("a", 64), cutoff.Add(5 * time.Minute)},
	} {
		if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{{
			CoordRequestID: row.id, SchemaVersion: 1, Revision: 1,
			ReceivedAt: row.at, UpdatedAt: row.at, Endpoint: "/v1/messages", HTTPStatus: 200,
			PublicDemand: &PublicDemandScope{Model: row.model, ConsumerHash: row.consumer, Outcome: "completed"},
		}}); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		for _, sql := range []string{
			`DROP TRIGGER IF EXISTS model_demand_prune_audit ON model_demand_hourly`,
			`DROP FUNCTION IF EXISTS model_demand_prune_audit()`,
			`DROP TABLE IF EXISTS model_demand_prune_audit_rows`,
		} {
			if _, err := s.pool.Exec(context.Background(), sql); err != nil {
				t.Errorf("cleanup retention audit: %v", err)
			}
		}
	})
	for _, sql := range []string{
		`CREATE TABLE model_demand_prune_audit_rows (deleted_rows bigint NOT NULL, transaction_id bigint NOT NULL)`,
		fmt.Sprintf(`CREATE FUNCTION model_demand_prune_audit() RETURNS trigger AS $$
		BEGIN
		 IF %d > 0 AND (SELECT count(*) FROM model_demand_prune_audit_rows WHERE deleted_rows>0) >= %d THEN
		  RAISE EXCEPTION 'forced hourly retention failure';
		 END IF;
		 INSERT INTO model_demand_prune_audit_rows SELECT count(*),txid_current() FROM deleted_rows;
		 RETURN NULL;
		END;
		$$ LANGUAGE plpgsql`, failAfter, failAfter),
		`CREATE TRIGGER model_demand_prune_audit AFTER DELETE ON model_demand_hourly
		 REFERENCING OLD TABLE AS deleted_rows FOR EACH STATEMENT EXECUTE FUNCTION model_demand_prune_audit()`,
	} {
		if _, err := s.pool.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	return cutoff.Add(30 * time.Minute)
}

func TestModelDemandPruneHourlyBatchesPostgres(t *testing.T) {
	for _, tc := range []struct {
		name           string
		batch, expired int
	}{
		{"small batch", 3, 8},
		{"default batch", 0, defaultTelemetryPruneBatch + 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := testPostgresStore(t)
			ctx := context.Background()
			before := modelDemandPruneFixture(t, s, tc.expired, 0)
			deleted, err := s.PruneModelDemand(ctx, before, tc.batch)
			if err != nil || deleted != tc.expired+2 {
				t.Fatalf("retention = %d, %v; want %d", deleted, err, tc.expired+2)
			}
			limit := tc.batch
			if limit <= 0 {
				limit = defaultTelemetryPruneBatch
			}
			var maximum, total, statements, transactions int
			if err := s.pool.QueryRow(ctx, `SELECT COALESCE(MAX(deleted_rows),0),COALESCE(SUM(deleted_rows),0),count(*),count(DISTINCT transaction_id)
				FROM model_demand_prune_audit_rows WHERE deleted_rows>0`).Scan(&maximum, &total, &statements, &transactions); err != nil {
				t.Fatal(err)
			}
			wantBatches := (tc.expired + limit - 1) / limit
			if maximum > limit || total != tc.expired || statements != wantBatches || transactions != statements {
				t.Fatalf("hourly deletes: max=%d total=%d statements=%d transactions=%d; limit=%d want_batches=%d", maximum, total, statements, transactions, limit, wantBatches)
			}
			var remaining int
			var earliest, latest time.Time
			if err := s.pool.QueryRow(ctx, `SELECT count(*),min(hour),max(hour) FROM model_demand_hourly`).Scan(&remaining, &earliest, &latest); err != nil {
				t.Fatal(err)
			}
			cutoffHour := before.UTC().Truncate(time.Hour)
			if remaining != 2 || !earliest.Equal(cutoffHour) || !latest.Equal(cutoffHour.Add(time.Hour)) {
				t.Fatalf("current/cutoff hours changed: count=%d first=%s last=%s", remaining, earliest, latest)
			}
			if again, err := s.PruneModelDemand(ctx, before, tc.batch); err != nil || again != 0 {
				t.Fatalf("repeated sweep = %d, %v", again, err)
			}
		})
	}
}

func TestModelDemandPrunePreservesCommittedBatchesPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	before := modelDemandPruneFixture(t, s, 8, 1)
	deleted, err := s.PruneModelDemand(ctx, before, 3)
	// Two projection deletes and the first three aggregate deletes committed;
	// the next aggregate transaction must roll back and terminate the sweep.
	if err == nil || deleted != 5 {
		t.Fatalf("interrupted retention = %d, %v; want 5 and error", deleted, err)
	}
	var remaining, committed int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM model_demand_hourly WHERE hour<$1`, before.Truncate(time.Hour)).Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(sum(deleted_rows),0) FROM model_demand_prune_audit_rows`).Scan(&committed); err != nil {
		t.Fatal(err)
	}
	if remaining != 5 || committed != 3 {
		t.Fatalf("committed/remaining hourly rows = %d/%d; want 3/5", committed, remaining)
	}
}

func TestModelDemandPruneHourlyLockTimeoutPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	before := modelDemandPruneFixture(t, s, 8, 0)
	locked, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer locked.Rollback(context.Background())
	var hour time.Time
	if err := locked.QueryRow(ctx, `SELECT hour FROM model_demand_hourly WHERE hour<$1
		ORDER BY hour,model,consumer_hash LIMIT 1 FOR UPDATE`, before.Truncate(time.Hour)).Scan(&hour); err != nil {
		t.Fatal(err)
	}
	deleted, err := s.PruneModelDemand(ctx, before, 3)
	var lockError *pgconn.PgError
	if deleted != 2 || !errors.As(err, &lockError) || lockError.Code != "55P03" {
		t.Fatalf("blocked hourly retention = %d, %v; want two committed projections and lock timeout", deleted, err)
	}
	var remaining int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM model_demand_hourly WHERE hour<$1`, before.Truncate(time.Hour)).Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if remaining != 8 {
		t.Fatalf("lock-timeout transaction removed rows: %d remain, want 8", remaining)
	}
}
