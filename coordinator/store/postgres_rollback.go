package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) CheckRollbackSafe(ctx context.Context) error {
	checks := []struct {
		table     string
		predicate string
	}{
		{
			table:     "rust_coord.inference_jobs",
			predicate: `COALESCE(status::text, '') NOT IN ('completed','failed','cancelled','released')`,
		},
		{
			table:     "rust_coord.financial_operations",
			predicate: `COALESCE(status::text, '') NOT IN ('applied','released','failed')`,
		},
		{
			table:     "rust_coord.external_events",
			predicate: `COALESCE(status::text, '') NOT IN ('applied','rejected','ignored','failed')`,
		},
		{
			table:     "rust_coord.outbox",
			predicate: `COALESCE(status::text, '') NOT IN ('delivered','failed','cancelled')`,
		},
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{
		IsoLevel: pgx.RepeatableRead,
	})
	if err != nil {
		return fmt.Errorf("store: begin rollback safety snapshot: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return err
	}
	var rustNamespaceExists, rustSchemaExists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM pg_namespace WHERE nspname = 'rust_coord'
		)`,
	).Scan(&rustNamespaceExists); err != nil {
		return fmt.Errorf("store: inspect Rust schema namespace: %w", err)
	}
	if err := tx.QueryRow(ctx,
		`SELECT to_regclass('rust_coord.schema_versions') IS NOT NULL`,
	).Scan(&rustSchemaExists); err != nil {
		return fmt.Errorf("store: inspect Rust schema compatibility: %w", err)
	}
	if !rustNamespaceExists {
		return tx.Commit(ctx)
	}
	if !rustSchemaExists {
		return fmt.Errorf(
			"store: unsafe Go rollback: rust_coord namespace has no schema_versions catalog",
		)
	}
	var rustMinimum, rustMaximum, rustCount int64
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(MIN(version), 0), COALESCE(MAX(version), 0), COUNT(*)
		 FROM rust_coord.schema_versions`,
	).Scan(&rustMinimum, &rustMaximum, &rustCount); err != nil {
		return fmt.Errorf("store: inspect Rust schema history: %w", err)
	}
	if rustMinimum != 1 || rustMaximum != 1 || rustCount != 1 {
		return fmt.Errorf(
			"store: unsafe Go rollback: unsupported Rust schema history min=%d max=%d count=%d",
			rustMinimum, rustMaximum, rustCount,
		)
	}
	rows, err := tx.Query(ctx, `
		SELECT relation.relname
		FROM pg_class relation
		JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
		WHERE namespace.nspname = 'rust_coord'
		  AND relation.relkind IN ('r', 'p')
		ORDER BY relation.relname`)
	if err != nil {
		return fmt.Errorf("store: inspect Rust rollback relations: %w", err)
	}
	defer rows.Close()
	knownRelations := map[string]bool{
		"schema_versions":      true,
		"inference_jobs":       true,
		"financial_operations": true,
		"external_events":      true,
		"outbox":               true,
	}
	for rows.Next() {
		var relation string
		if err := rows.Scan(&relation); err != nil {
			return fmt.Errorf("store: inspect Rust rollback relation: %w", err)
		}
		if !knownRelations[relation] {
			return fmt.Errorf(
				"store: unsafe Go rollback: unknown Rust relation rust_coord.%s",
				relation,
			)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("store: inspect Rust rollback relations: %w", err)
	}
	rows.Close()
	for _, check := range checks {
		var exists bool
		if err := tx.QueryRow(ctx,
			`SELECT to_regclass($1) IS NOT NULL`,
			check.table,
		).Scan(&exists); err != nil {
			return fmt.Errorf("store: inspect rollback table %s: %w", check.table, err)
		}
		if !exists {
			continue
		}
		var unresolved int64
		query := "SELECT count(*) FROM " + check.table + " WHERE " + check.predicate
		if err := tx.QueryRow(ctx, query).Scan(&unresolved); err != nil {
			return fmt.Errorf("store: inspect unresolved %s: %w", check.table, err)
		}
		if unresolved > 0 {
			return fmt.Errorf(
				"store: unsafe Go rollback: %s contains %d unresolved row(s)",
				check.table,
				unresolved,
			)
		}
	}
	return tx.Commit(ctx)
}
