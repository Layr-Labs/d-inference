package postgres_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestAutopilotCohortQueryCountDoesNotGrowWithFleet(t *testing.T) {
	counts := make(map[int]int)
	for _, size := range []int{1, 2000} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			f, tracer, anchor := cohortQueryFixture(t, size)
			positive := earningsfloor.Consent{SessionID: "target", AccountID: "target", Supported: true, Qualified: true, OptedIn: true, Chip: "M4 Max", MemoryGB: 128, At: anchor}
			tracer.reset()
			started := time.Now()
			got, err := f.ObserveAutopilotConsent(t.Context(), positive)
			elapsed := time.Since(started)
			if err != nil || !got.BaselineKnown || got.BaselineSource != earningsfloor.CohortBaseline || got.SevenDayEarningsMicroUSD != 70 {
				t.Fatalf("cohort enrollment with %d machines: %+v %v", size, got, err)
			}
			statements := tracer.snapshot()
			counts[size] = len(statements)
			t.Logf("cohort enrollment: fleet=%d queries=%d elapsed=%s", size, len(statements), elapsed)
			identities := 0
			for _, statement := range statements {
				if strings.Contains(statement.sql, "WITH RECURSIVE chain AS") {
					identities++
				}
			}
			if identities > 3 || len(statements) > 40 {
				t.Fatalf("cohort enrollment queried individual peers: size=%d queries=%d identity_lookups=%d", size, len(statements), identities)
			}
		})
	}
	if counts[1] != counts[2000] {
		t.Fatalf("query count grew with nonmatching fleet: %v", counts)
	}
}

func TestAutopilotConsentJournalDoesNotQueryCohortOrCreateEnrollment(t *testing.T) {
	f, tracer, anchor := cohortQueryFixture(t, 2000)
	tracer.reset()
	started := time.Now()
	err := f.RecordAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "target", AccountID: "target", Supported: true, Qualified: true, OptedIn: true, Chip: "M4 Max", MemoryGB: 128, At: anchor})
	if err != nil {
		t.Fatal(err)
	}
	statements := tracer.snapshot()
	t.Logf("consent journal: fleet=2000 queries=%d elapsed=%s", len(statements), time.Since(started))
	for _, statement := range statements {
		if strings.Contains(statement.sql, "provider_earnings") || strings.Contains(statement.sql, "INSERT INTO autopilot_reward_enrollments") || strings.Contains(statement.sql, "FOR UPDATE") && strings.Contains(statement.sql, "autopilot_reward_pool") {
			t.Fatalf("journal performed reward materialization: %s", statement.sql)
		}
	}
	if len(statements) > 15 {
		t.Fatalf("journal query count unexpectedly grows with cohort: %d", len(statements))
	}
	var consents, enrollments int
	if err := f.pool.QueryRow(t.Context(), `SELECT
	 (SELECT count(*) FROM autopilot_reward_consents WHERE session_id='target' AND opted_in),
	 (SELECT count(*) FROM autopilot_reward_enrollments)`).Scan(&consents, &enrollments); err != nil {
		t.Fatal(err)
	}
	if consents != 1 || enrollments != 0 {
		t.Fatalf("journal did not persist only consent: consents=%d enrollments=%d", consents, enrollments)
	}
}

func cohortQueryFixture(t *testing.T, size int) (*postgresFixture, *statementTracer, time.Time) {
	t.Helper()
	tracer := &statementTracer{}
	f, err := newPostgresWithPoolConfig(t.Context(), store.Config{DatabaseURL: newThrowawayTestDatabase(t)}, func(cfg *pgxpool.Config) {
		cfg.ConnConfig.Tracer = tracer
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.Close)
	anchor := time.Now().UTC().Add(-24 * time.Hour).Truncate(time.Microsecond)
	mature := anchor.Add(-10 * 24 * time.Hour)
	if _, err := f.pool.Exec(t.Context(), `UPDATE autopilot_reward_pool SET tracking_started_at=$1`, mature.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{
		`INSERT INTO darkbloom_machines(id,assurance,first_seen,last_seen)
		 SELECT 'peer:'||i,'key_bound',$2,$2 FROM generate_series(1,$1::int) i`,
		`INSERT INTO darkbloom_machine_sessions(session_id,machine_id,original_machine_id,account_id,first_seen,last_seen,observation)
		 SELECT 'peer:'||i,'peer:'||i,'peer:'||i,'owner:'||i,$2,$2,
		 jsonb_build_object('chip',CASE WHEN i=1 THEN 'M4 Max' ELSE 'M3 Max' END,'memory_gb',128)
		 FROM generate_series(1,$1::int) i`,
		`INSERT INTO darkbloom_machine_observations(session_id,observed_at,observation)
		 SELECT 'peer:'||i,$2,jsonb_build_object('chip',CASE WHEN i=1 THEN 'M4 Max' ELSE 'M3 Max' END,'memory_gb',128)
		 FROM generate_series(1,$1::int) i`,
		`INSERT INTO provider_earnings(account_id,provider_id,provider_key,job_id,model,amount_micro_usd,created_at)
		 SELECT 'owner:'||i,'peer:'||i,'key:'||i,'job:'||i,'inference',70,$2::timestamptz+interval '9 days' FROM generate_series(1,$1::int) i`,
	} {
		if _, err := f.pool.Exec(t.Context(), query, size, mature); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.pool.Exec(t.Context(), `ANALYZE darkbloom_machines; ANALYZE darkbloom_machine_sessions; ANALYZE darkbloom_machine_observations; ANALYZE provider_earnings`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ObserveMachine(t.Context(), store.MachineObservation{SessionID: "target", AccountID: "target", SEKey: "target-key", Chip: "M4 Max", MemoryGB: 128, At: anchor.Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "target", AccountID: "target", Supported: true, At: anchor.Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	return f, tracer, anchor
}
