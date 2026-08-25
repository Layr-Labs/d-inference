package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestProviderLogReportSerialPrivacyMigration(t *testing.T) {
	combined := strings.Join([]string{
		providerLogReportSerialGuardFunction,
		providerLogReportSerialGuardTrigger,
		providerLogReportSerialScrubMigration,
	}, "\n")
	for _, required := range []string{
		"NEW.serial_number := ''",
		"BEFORE INSERT OR UPDATE OF serial_number",
		"UPDATE provider_log_reports SET serial_number = ''",
		"scrub_provider_log_report_serials_v1",
	} {
		if !strings.Contains(combined, required) {
			t.Fatalf("provider log report privacy migration missing %q", required)
		}
	}
}

func TestProviderLogReportSerialPrivacyMigrationPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	schema := fmt.Sprintf("log_report_privacy_%d", time.Now().UnixNano())
	if _, err := s.pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create isolated schema: %v", err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+schema+" CASCADE")
	})

	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire isolated migration connection: %v", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SET search_path TO "+schema); err != nil {
		t.Fatalf("set isolated search_path: %v", err)
	}

	for _, statement := range []string{
		`CREATE TABLE schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE provider_log_reports (
			id BIGSERIAL PRIMARY KEY,
			serial_number TEXT NOT NULL,
			provider_id TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			log_data BYTEA NOT NULL,
			log_size_bytes BIGINT NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX idx_log_reports_serial
			ON provider_log_reports(serial_number, created_at DESC)`,
		`INSERT INTO provider_log_reports (serial_number, account_id, log_data)
			VALUES ('historical-hardware-identity', 'account-1', '\x01')`,
		providerLogReportSerialGuardFunction,
		providerLogReportSerialGuardTrigger,
		providerLogReportSerialScrubMigration,
		`DROP INDEX IF EXISTS idx_log_reports_serial`,
	} {
		if _, err := conn.Exec(ctx, statement); err != nil {
			t.Fatalf("prepare or run log report privacy migration: %v\n%s", err, statement)
		}
	}

	var historicalSerial, insertedSerial, updatedSerial string
	if err := conn.QueryRow(ctx,
		`SELECT serial_number FROM provider_log_reports WHERE account_id = 'account-1'`,
	).Scan(&historicalSerial); err != nil {
		t.Fatalf("read scrubbed report: %v", err)
	}
	if err := conn.QueryRow(ctx, `
		INSERT INTO provider_log_reports (serial_number, account_id, log_data)
		VALUES ('new-hardware-identity', 'account-2', '\x02')
		RETURNING serial_number`,
	).Scan(&insertedSerial); err != nil {
		t.Fatalf("insert guarded report: %v", err)
	}
	if err := conn.QueryRow(ctx, `
		UPDATE provider_log_reports
		SET serial_number = 'replacement-hardware-identity'
		WHERE account_id = 'account-2'
		RETURNING serial_number`,
	).Scan(&updatedSerial); err != nil {
		t.Fatalf("update guarded report: %v", err)
	}
	if historicalSerial != "" || insertedSerial != "" || updatedSerial != "" {
		t.Fatalf(
			"provider log report identity survived privacy controls: historical=%q insert=%q update=%q",
			historicalSerial,
			insertedSerial,
			updatedSerial,
		)
	}

	var markerExists, indexExists bool
	if err := conn.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM schema_migrations
			WHERE id = 'scrub_provider_log_report_serials_v1'
		)`,
	).Scan(&markerExists); err != nil {
		t.Fatalf("read scrub marker: %v", err)
	}
	if err := conn.QueryRow(ctx, `
		SELECT to_regclass(current_schema() || '.idx_log_reports_serial') IS NOT NULL`,
	).Scan(&indexExists); err != nil {
		t.Fatalf("check retired serial index: %v", err)
	}
	if !markerExists {
		t.Fatal("provider log report serial scrub marker was not recorded")
	}
	if indexExists {
		t.Fatal("provider log report serial index still exists")
	}

	for _, statement := range []string{
		providerLogReportSerialGuardFunction,
		providerLogReportSerialGuardTrigger,
		providerLogReportSerialScrubMigration,
		`DROP INDEX IF EXISTS idx_log_reports_serial`,
	} {
		if _, err := conn.Exec(ctx, statement); err != nil {
			t.Fatalf("re-run log report privacy migration: %v\n%s", err, statement)
		}
	}
}
