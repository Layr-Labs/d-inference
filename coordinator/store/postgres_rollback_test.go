package store

import (
	"context"
	"strings"
	"testing"
)

func TestPostgresRollbackGuardRejectsUnresolvedRustState(t *testing.T) {
	backend := testPostgresStore(t)
	ctx := context.Background()
	if _, err := backend.pool.Exec(ctx,
		`ALTER TABLE rust_coord.schema_versions RENAME TO schema_versions_hidden`); err != nil {
		t.Fatal(err)
	}
	catalogRenamed := true
	t.Cleanup(func() {
		if catalogRenamed {
			_, _ = backend.pool.Exec(context.Background(),
				`ALTER TABLE rust_coord.schema_versions_hidden RENAME TO schema_versions`)
		}
	})
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "has no schema_versions") {
		t.Fatalf("missing Rust schema catalog guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx,
		`ALTER TABLE rust_coord.schema_versions_hidden RENAME TO schema_versions`); err != nil {
		t.Fatal(err)
	}
	catalogRenamed = false
	const dropTestTables = `
		DROP TABLE IF EXISTS rust_coord.inference_jobs;
		DROP TABLE IF EXISTS rust_coord.financial_operations;
		DROP TABLE IF EXISTS rust_coord.external_events;
		DROP TABLE IF EXISTS rust_coord.outbox`
	if _, err := backend.pool.Exec(ctx, dropTestTables); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = backend.pool.Exec(context.Background(), dropTestTables)
		_, _ = backend.pool.Exec(context.Background(),
			`DELETE FROM rust_coord.schema_versions WHERE version > 1`)
	})
	if err := backend.CheckRollbackSafe(ctx); err != nil {
		t.Fatalf("absent Rust schema: %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		CREATE TABLE rust_coord.inference_jobs (status TEXT NOT NULL);
		CREATE TABLE rust_coord.outbox (status TEXT NOT NULL);
		CREATE TABLE rust_coord.external_events (status TEXT);
		INSERT INTO rust_coord.inference_jobs VALUES ('running')`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "inference_jobs") {
		t.Fatalf("running job guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.inference_jobs SET status = 'completed';
		INSERT INTO rust_coord.outbox VALUES ('external_unknown')`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "outbox") {
		t.Fatalf("pending outbox guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx,
		`UPDATE rust_coord.outbox SET status = 'delivered'`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err != nil {
		t.Fatalf("terminal Rust state rejected: %v", err)
	}
	if _, err := backend.pool.Exec(ctx,
		`INSERT INTO rust_coord.external_events VALUES (NULL)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "external_events") {
		t.Fatalf("unknown external status guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx,
		`UPDATE rust_coord.external_events SET status = 'failed';
		 CREATE TABLE rust_coord.unrecognized_work (id BIGINT PRIMARY KEY)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "unknown Rust relation") {
		t.Fatalf("unknown Rust relation guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		DROP TABLE rust_coord.unrecognized_work;
		INSERT INTO rust_coord.schema_versions (
			version, minimum_public_schema_version, maximum_public_schema_version
		) VALUES (2, 3, 3)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "unsupported Rust schema history") {
		t.Fatalf("newer Rust schema guard error = %v", err)
	}
}
