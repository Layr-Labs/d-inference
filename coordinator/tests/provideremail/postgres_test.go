package provideremail_test

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// This test creates only a unique disposable schema. Unlike store's harness it
// does not truncate shared tables, so CI may run the packages concurrently.
func TestReadSnapshotPostgres(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set — disposable PostgreSQL required")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	schema := "provider_email_test_" + uuid.NewString()[:8]
	if _, err = conn.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
	_, err = conn.Exec(ctx, `SET search_path TO `+schema+`;
CREATE TABLE users(account_id text primary key,email text);
CREATE TABLE darkbloom_machines(id text primary key,merged_into text);
CREATE TABLE darkbloom_machine_sessions(session_id text primary key,machine_id text,account_id text,first_seen timestamptz,last_seen timestamptz,observation jsonb);
CREATE TABLE providers(id text primary key,last_seen timestamptz);
INSERT INTO users VALUES ('old-owner','old@example.com'),('new-owner','new@example.com');
INSERT INTO darkbloom_machines VALUES ('transferred',NULL),('anonymous',NULL),('historical',NULL),('merged','transferred');`)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	add := func(id, machine, account, source string, start, seen time.Time) {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"source": source, "registered_at": start, "version": "0.9.3", "os_version": "26.5", "os_source": "registration_report", "os_observed_at": now})
		_, err := conn.Exec(ctx, `INSERT INTO darkbloom_machine_sessions VALUES($1,$2,$3,$4,$5,$6)`, id, machine, account, start, seen, raw)
		if err != nil {
			t.Fatal(err)
		}
	}
	// The old session has a later last_seen; its delayed disconnect must not
	// override the owner of the newer registration.
	add("old", "transferred", "old-owner", "live_registration", now.Add(-time.Hour), now)
	add("new", "transferred", "new-owner", "live_registration", now.Add(-time.Minute), now.Add(-time.Second))
	add("anon-old", "anonymous", "old-owner", "live_registration", now.Add(-time.Hour), now)
	add("anon-new", "anonymous", "", "live_registration", now.Add(-time.Minute), now)
	add("history", "historical", "old-owner", "historical_registration", now.Add(-time.Minute), now)
	add("merged", "merged", "old-owner", "live_registration", now, now)
	// An old connection's first inventory write can succeed only after a newer
	// connection registered. Neither capture time nor heartbeat time is order.
	if _, err = conn.Exec(ctx, `UPDATE darkbloom_machine_sessions SET first_seen=$1 WHERE session_id='old'`, now); err != nil {
		t.Fatal(err)
	}
	if _, err = conn.Exec(ctx, `INSERT INTO providers VALUES ('untracked',$1),('new',$1)`, now); err != nil {
		t.Fatal(err)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	// URL-form connection strings accept search_path as a runtime parameter.
	var testDSN string
	if cfg.Host == "" {
		t.Fatal("missing database host")
	}
	testDSN = dsn + " search_path=" + schema
	if len(dsn) >= 8 && (dsn[:8] == "postgres") {
		separator := "?"
		for _, ch := range dsn {
			if ch == '?' {
				separator = "&"
			}
		}
		testDSN = dsn + separator + "search_path=" + schema
	}
	s, err := provideremail.ReadSnapshot(ctx, testDSN, 30)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Machines) != 3 || s.UntrackedSessions != 1 {
		t.Fatalf("%+v", s)
	}
	a, err := provideremail.BuildAudience(testCampaign(), s, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Recipients) != 1 || a.Recipients[0].Email != "new@example.com" || a.Counts.UnknownOwner != 1 || a.Counts.Historical != 1 {
		t.Fatalf("%+v", a)
	}
	if _, err := conn.Exec(ctx, `CREATE TEMP TABLE campaign_sessions_fixture AS TABLE darkbloom_machine_sessions`); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name                        string
		query                       string
		wantRecipients, wantUnknown int
	}{
		{"updated", `UPDATE darkbloom_machine_sessions SET observation=observation || '{"version":"0.9.4"}' WHERE session_id='new'`, 0, 0},
		{"anonymous", `UPDATE darkbloom_machine_sessions SET account_id='' WHERE session_id='new'`, 0, 0},
		{"historical", `UPDATE darkbloom_machine_sessions SET observation=observation || '{"source":"historical_registration"}' WHERE session_id='new'`, 0, 0},
		{"inactive", `UPDATE darkbloom_machine_sessions SET last_seen=last_seen - interval '31 days' WHERE session_id='new'`, 0, 0},
		{"undated newest", `UPDATE darkbloom_machine_sessions SET observation=observation - 'registered_at' WHERE session_id='new'`, 0, 1},
		{"undated delayed old capture", `UPDATE darkbloom_machine_sessions SET observation=observation - 'registered_at' WHERE session_id='old'`, 0, 1},
		{"zero registration", `UPDATE darkbloom_machine_sessions SET observation=observation || '{"registered_at":"0001-01-01T00:00:00Z"}' WHERE session_id='new'`, 0, 1},
		{"proven older legacy", `UPDATE darkbloom_machine_sessions SET first_seen=(observation->>'registered_at')::timestamptz, observation=observation - 'registered_at' WHERE session_id='old'`, 1, 0},
		{"undated tie", `UPDATE darkbloom_machine_sessions SET first_seen=(SELECT (observation->>'registered_at')::timestamptz FROM darkbloom_machine_sessions WHERE session_id='new'), observation=observation - 'registered_at' WHERE session_id='old'`, 0, 1},
		{"dated tie", `UPDATE darkbloom_machine_sessions SET observation=jsonb_set(observation, '{registered_at}', (SELECT observation->'registered_at' FROM darkbloom_machine_sessions WHERE session_id='new')) WHERE session_id='old'`, 0, 1},
		{"submicrosecond tie", `UPDATE darkbloom_machine_sessions SET observation=jsonb_set(observation, '{registered_at}', to_jsonb(CASE WHEN session_id='old' THEN '2026-01-01T00:00:00.0000001Z' ELSE '2026-01-01T00:00:00.0000002Z' END)) WHERE session_id IN ('old','new')`, 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := conn.Exec(ctx, `TRUNCATE darkbloom_machine_sessions; INSERT INTO darkbloom_machine_sessions SELECT * FROM campaign_sessions_fixture`); err != nil {
				t.Fatal(err)
			}
			if _, err := conn.Exec(ctx, tc.query); err != nil {
				t.Fatal(err)
			}
			snapshot, err := provideremail.ReadSnapshot(ctx, testDSN, 30)
			if err != nil {
				t.Fatal(err)
			}
			audience, err := provideremail.BuildAudience(testCampaign(), snapshot, time.Now().UTC())
			if err != nil {
				t.Fatal(err)
			}
			if len(audience.Recipients) != tc.wantRecipients || audience.Counts.UnknownRegistration != tc.wantUnknown || audience.Counts.Machines != 3 {
				t.Fatalf("unexpected audience: %+v", audience)
			}
			for _, recipient := range audience.Recipients {
				if recipient.Email != "new@example.com" {
					t.Fatalf("selected an old owner: %+v", recipient)
				}
			}
		})
	}
}
