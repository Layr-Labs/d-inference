package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) CheckRollbackSafe(ctx context.Context) error {
	checks := []struct {
		minVersion int64
		table      string
		predicate  string
	}{
		{
			minVersion: 2,
			table:      "rust_coord.inference_jobs",
			predicate:  `state NOT IN ('settled','released','settled_reviewed','released_reviewed') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.inference_attempts",
			predicate:  `state NOT IN ('aborted','acknowledged') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.provider_terminals",
			predicate:  `status NOT IN ('settled','released','settled_reviewed','released_reviewed','duplicate','late','rejected') OR (conflict AND status NOT IN ('settled_reviewed','released_reviewed')) OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.financial_operations",
			predicate:  `status NOT IN ('applied','released','failed') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.external_events",
			predicate:  `status NOT IN ('applied','rejected','ignored','failed') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.outbox",
			predicate:  `status NOT IN ('delivered','failed','cancelled') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.fee_allocations",
			predicate:  `status NOT IN ('projected','cancelled') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 2,
			table:      "rust_coord.fee_projection_checkpoints",
			predicate:  `status <> 'idle' OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
		},
		{
			minVersion: 4,
			table:      "rust_coord.mdm_command_expectations",
			predicate:  `status = 'pending'`,
		},
		{
			minVersion: 4,
			table:      "rust_coord.telemetry_events",
			predicate:  `status NOT IN ('delivered','dropped') OR worker_owner IS NOT NULL OR lease_until IS NOT NULL`,
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
	var (
		rustMinimum int64
		rustMaximum int64
		rustCount   int64
	)
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(MIN(version), 0), COALESCE(MAX(version), 0), COUNT(*)
		 FROM rust_coord.schema_versions`,
	).Scan(&rustMinimum, &rustMaximum, &rustCount); err != nil {
		return fmt.Errorf("store: inspect Rust schema history: %w", err)
	}
	if rustMinimum != 1 || rustCount != rustMaximum ||
		(rustMaximum != 1 && rustMaximum != 2 && rustMaximum != 3 && rustMaximum != 4) {
		return fmt.Errorf(
			"store: unsafe Go rollback: unsupported Rust schema history min=%d max=%d count=%d",
			rustMinimum, rustMaximum, rustCount,
		)
	}
	if rustMaximum == 1 {
		var minimumPublic, maximumPublic int64
		if err := tx.QueryRow(ctx, `
			SELECT minimum_public_schema_version, maximum_public_schema_version
			FROM rust_coord.schema_versions
			WHERE version = 1`,
		).Scan(&minimumPublic, &maximumPublic); err != nil {
			return fmt.Errorf("store: inspect Rust schema v1 compatibility: %w", err)
		}
		if minimumPublic != 3 || maximumPublic != 3 {
			return fmt.Errorf(
				"store: unsafe Go rollback: unsupported Rust schema v1 compatibility [%d,%d]",
				minimumPublic,
				maximumPublic,
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
		var relations []string
		for rows.Next() {
			var relation string
			if err := rows.Scan(&relation); err != nil {
				rows.Close()
				return fmt.Errorf("store: inspect Rust rollback relation: %w", err)
			}
			relations = append(relations, relation)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return fmt.Errorf("store: inspect Rust rollback relations: %w", err)
		}
		rows.Close()
		if len(relations) != 1 || relations[0] != "schema_versions" {
			return fmt.Errorf(
				"store: unsafe Go rollback: Rust schema v1 has unknown relations %v",
				relations,
			)
		}
		return tx.Commit(ctx)
	}
	if err := validateRustSchemaV2Shape(ctx, tx); err != nil {
		return fmt.Errorf("store: unsafe Go rollback: unknown Rust schema v%d shape: %w", rustMaximum, err)
	}
	for _, check := range checks {
		if rustMaximum < check.minVersion {
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
