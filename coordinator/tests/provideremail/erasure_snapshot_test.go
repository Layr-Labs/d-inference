package provideremail_test

import (
	"context"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func TestReadSnapshotExcludesErasingOwnerAfterRanking(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	schema := "provider_email_erasure_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err := conn.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
	_, err = conn.Exec(ctx, `SET search_path TO `+schema+`;
CREATE TABLE users(account_id text primary key,email text,deleted_at timestamptz);
CREATE TABLE darkbloom_machines(id text primary key,merged_into text);
CREATE TABLE darkbloom_machine_sessions(session_id text primary key,machine_id text,account_id text,first_seen timestamptz,last_seen timestamptz,observation jsonb);
CREATE TABLE providers(id text primary key,last_seen timestamptz);
INSERT INTO users VALUES ('old','old@example.com',NULL),('erasing','erasing@example.com',NOW()),('live','live@example.com',NULL);
INSERT INTO darkbloom_machines VALUES ('transferred',NULL),('active',NULL);
INSERT INTO darkbloom_machine_sessions
SELECT id, machine, account, NOW() - age, NOW(),
 jsonb_build_object('registered_at', NOW() - age, 'source','live_registration','version','0.9.3','os_version','26.5','os_source','registration_report','os_observed_at',NOW())
FROM (VALUES ('old-session','transferred','old',interval '2 hours'),
 ('new-session','transferred','erasing',interval '1 hour'),
 ('live-session','active','live',interval '1 hour')) AS fixture(id,machine,account,age);`)
	if err != nil {
		t.Fatal(err)
	}
	testDSN := dsn + " search_path=" + schema
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatal(err)
		}
		q := u.Query()
		q.Set("search_path", schema)
		u.RawQuery = q.Encode()
		testDSN = u.String()
	}
	for _, scrubbed := range []bool{false, true} {
		if scrubbed {
			if _, err := conn.Exec(ctx, `UPDATE users SET email='' WHERE account_id='erasing'`); err != nil {
				t.Fatal(err)
			}
		}
		snapshot, err := provideremail.ReadSnapshot(ctx, testDSN, 30)
		if err != nil {
			t.Fatal(err)
		}
		for _, machine := range snapshot.Machines {
			if machine.ID == "transferred" && (machine.AccountID != "erasing" || machine.Email != "") {
				t.Fatal("deleted latest owner exposed contact or resurrected previous owner")
			}
		}
		audience, err := provideremail.BuildAudience(testCampaign(), snapshot, time.Now().UTC())
		if err != nil {
			t.Fatal(err)
		}
		if len(audience.Recipients) != 1 || audience.Recipients[0].Email != "live@example.com" {
			t.Fatal("expected only the unrelated live owner's contact")
		}
	}
}
