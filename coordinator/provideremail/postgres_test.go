package provideremail

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

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
		raw, _ := json.Marshal(map[string]any{"source": source, "version": "0.9.3", "os_version": "26.5", "os_source": "registration_report", "os_observed_at": now})
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
	s, err := ReadSnapshot(ctx, testDSN, 30)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Machines) != 3 || s.UntrackedSessions != 1 {
		t.Fatalf("%+v", s)
	}
	a, err := BuildAudience(testCampaign(), s, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Recipients) != 1 || a.Recipients[0].Email != "new@example.com" || a.Counts.UnknownOwner != 1 || a.Counts.Historical != 1 {
		t.Fatalf("%+v", a)
	}
}
