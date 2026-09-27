package store

import (
	"context"
	"testing"
	"time"
)

func TestPostgresPredictionColumnsUpgradeKeepsUnknownHistory(t *testing.T) {
	s := testPostgresStore(t) // Explicit disposable DATABASE_URL only.
	ctx := context.Background()
	old := fullProfile("before-prediction-telemetry", 0, time.Now())
	old.AdmissionMode = ""
	if err := s.RecordRequestProfiles([]*RequestProfileRecord{old}); err != nil {
		t.Fatal(err)
	}
	// Reproduce the previous schema in the isolated test database, including
	// a real historical row. The view is separately managed and may exist
	// from other tests; production migration never drops it.
	if _, err := s.pool.Exec(ctx, `DROP VIEW IF EXISTS request_waterfall;
		ALTER TABLE request_profiles DROP COLUMN predictive_bypass,
		DROP COLUMN reservation_ttft_ceiling_ms, DROP COLUMN dispatch_budget_ms`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := s.migrate(ctx); err != nil {
			t.Fatalf("upgrade %d: %v", i, err)
		}
	}
	rows := s.RequestProfilesSince(time.Time{})
	if len(rows) != 1 || rows[0].RequestID != old.RequestID || rows[0].AdmissionMode != "" || rows[0].PredictiveBypass != "" || rows[0].ReservationTTFTCeilingMs != nil || rows[0].DispatchBudgetMs != nil {
		t.Fatalf("upgrade fabricated or lost historical evidence: %+v", rows)
	}
	fresh := fullProfile("after-prediction-telemetry", 0, time.Now())
	if err := s.RecordRequestProfiles([]*RequestProfileRecord{fresh}); err != nil {
		t.Fatal(err)
	}
	rows = s.RequestProfilesSince(time.Time{})
	if len(rows) != 2 || rows[0].RequestID != fresh.RequestID || rows[0].DispatchBudgetMs == nil || *rows[0].DispatchBudgetMs != *fresh.DispatchBudgetMs || rows[0].ReservationTTFTCeilingMs == nil || *rows[0].ReservationTTFTCeilingMs != *fresh.ReservationTTFTCeilingMs {
		t.Fatalf("upgraded schema lost new evidence: %+v", rows)
	}
}
