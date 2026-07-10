package store

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
)

type columnShapeRequirement struct {
	Table   string
	Column  string
	Type    string
	NotNull bool
}

type keyShapeRequirement struct {
	Table   string
	Kind    string
	Columns []string
}

var legacyTableFingerprint = []string{
	"api_keys",
	"balance_reservation_operations",
	"balances",
	"billing_sessions",
	"code_attestations",
	"coordinator_ownership",
	"device_codes",
	"earnings_summary",
	"inference_completion_intents",
	"inference_routes",
	"inference_settlement_reviews",
	"inference_settlements",
	"invite_codes",
	"invite_redemptions",
	"ledger_entries",
	"model_active_versions",
	"model_aliases",
	"model_prices",
	"model_registry",
	"model_version_files",
	"model_versions",
	"payments",
	"provider_earnings",
	"provider_floor_draws",
	"provider_log_reports",
	"provider_payouts",
	"provider_reputation",
	"provider_sessions",
	"provider_tokens",
	"provider_trust_reuse",
	"providers",
	"publishing_api_keys",
	"referrals",
	"referrers",
	"releases",
	"request_rejections",
	"schema_migrations",
	"stripe_deposit_events",
	"stripe_sweep_failures",
	"stripe_withdrawals",
	"usage",
	"usage_totals",
	"users",
}

var legacySequenceNames = []string{
	"inference_routes_id_seq",
	"ledger_entries_id_seq",
	"model_version_files_id_seq",
	"model_versions_id_seq",
	"payments_id_seq",
	"provider_earnings_id_seq",
	"provider_floor_draws_id_seq",
	"provider_log_reports_id_seq",
	"provider_payouts_id_seq",
	"provider_sessions_id_seq",
	"request_rejections_id_seq",
	"usage_id_seq",
}

var criticalColumnShapes = []columnShapeRequirement{
	{Table: schemaMigrationTable, Column: "version", Type: "bigint", NotNull: true},
	{Table: schemaMigrationTable, Column: "name", Type: "text", NotNull: true},
	{Table: schemaMigrationTable, Column: "checksum", Type: "text", NotNull: true},
	{Table: schemaMigrationTable, Column: "transactional", Type: "boolean", NotNull: true},
	{Table: "coordinator_ownership", Column: "singleton", Type: "boolean", NotNull: true},
	{Table: "coordinator_ownership", Column: "epoch", Type: "bigint", NotNull: true},
	{Table: "coordinator_ownership", Column: "owner_id", Type: "text", NotNull: true},
	{Table: "providers", Column: "id", Type: "text", NotNull: true},
	{Table: "api_keys", Column: "key_hash", Type: "text", NotNull: true},
	{Table: "api_keys", Column: "id", Type: "text", NotNull: true},
	{Table: "usage", Column: "id", Type: "bigint", NotNull: true},
	{Table: "usage", Column: "request_id", Type: "text", NotNull: true},
	{Table: "users", Column: "account_id", Type: "text", NotNull: true},
	{Table: "users", Column: "privy_user_id", Type: "text", NotNull: true},
	{Table: "balances", Column: "account_id", Type: "text", NotNull: true},
	{Table: "balances", Column: "balance_micro_usd", Type: "bigint", NotNull: true},
	{Table: "balances", Column: "withdrawable_micro_usd", Type: "bigint", NotNull: true},
	{Table: "ledger_entries", Column: "id", Type: "bigint", NotNull: true},
	{Table: "ledger_entries", Column: "account_id", Type: "text", NotNull: true},
	{Table: "ledger_entries", Column: "amount_micro_usd", Type: "bigint", NotNull: true},
	{Table: "inference_settlements", Column: "reservation_id", Type: "text", NotNull: true},
	{Table: "inference_settlements", Column: "request_id", Type: "text", NotNull: true},
	{Table: "provider_earnings", Column: "id", Type: "bigint", NotNull: true},
	{Table: "provider_earnings", Column: "job_id", Type: "text", NotNull: true},
	{Table: "provider_earnings", Column: "provider_key", Type: "text", NotNull: true},
	{Table: "model_registry", Column: "id", Type: "text", NotNull: true},
	{Table: "releases", Column: "version", Type: "text", NotNull: true},
	{Table: "releases", Column: "platform", Type: "text", NotNull: true},
	{Table: "inference_routes", Column: "id", Type: "bigint", NotNull: true},
	{Table: "inference_routes", Column: "request_id", Type: "text", NotNull: true},
	{Table: "inference_routes", Column: "attempt", Type: "integer", NotNull: true},
}

var criticalKeyShapes = []keyShapeRequirement{
	{Table: schemaMigrationTable, Kind: "p", Columns: []string{"version"}},
	{Table: "coordinator_ownership", Kind: "p", Columns: []string{"singleton"}},
	{Table: "providers", Kind: "p", Columns: []string{"id"}},
	{Table: "api_keys", Kind: "p", Columns: []string{"key_hash"}},
	{Table: "usage", Kind: "p", Columns: []string{"id"}},
	{Table: "users", Kind: "p", Columns: []string{"account_id"}},
	{Table: "users", Kind: "u", Columns: []string{"privy_user_id"}},
	{Table: "balances", Kind: "p", Columns: []string{"account_id"}},
	{Table: "ledger_entries", Kind: "p", Columns: []string{"id"}},
	{Table: "inference_settlements", Kind: "p", Columns: []string{"reservation_id"}},
	{Table: "provider_earnings", Kind: "p", Columns: []string{"id"}},
	{Table: "model_registry", Kind: "p", Columns: []string{"id"}},
	{Table: "releases", Kind: "p", Columns: []string{"version", "platform"}},
	{Table: "inference_routes", Kind: "p", Columns: []string{"id"}},
	{Table: "inference_routes", Kind: "u", Columns: []string{"request_id", "attempt"}},
}

func schemaIsEmpty(ctx context.Context, queryer schemaQueryer) (bool, error) {
	var empty bool
	err := queryer.QueryRow(ctx, `
		SELECT NOT EXISTS (
			SELECT 1
			FROM pg_class relation
			JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
			WHERE namespace.nspname = COALESCE(
				NULLIF(current_setting('darkbloom.migration_schema', true), ''),
				current_schema()
			)
			  AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
		)`).Scan(&empty)
	if err != nil {
		return false, fmt.Errorf("inspect unversioned database contents: %w", err)
	}
	return empty, nil
}

func validateLegacySchemaFingerprint(ctx context.Context, queryer schemaQueryer) error {
	if err := validateOnlyKnownLegacyRelations(ctx, queryer, false); err != nil {
		return err
	}
	for _, table := range legacyTableFingerprint {
		exists, err := tableExists(ctx, queryer, table)
		if err != nil {
			return err
		}
		if !exists {
			return fmt.Errorf("required legacy table %q is missing", table)
		}
	}
	if err := validateCriticalColumns(ctx, queryer, false, false); err != nil {
		return err
	}
	if err := validateCriticalKeys(ctx, queryer, false); err != nil {
		return err
	}
	return nil
}

func validateBootstrapRetryState(ctx context.Context, queryer schemaQueryer) error {
	if err := validateOnlyKnownLegacyRelations(ctx, queryer, true); err != nil {
		return err
	}
	if err := validateCriticalColumns(ctx, queryer, true, true); err != nil {
		return err
	}
	if err := validateCriticalKeys(ctx, queryer, true); err != nil {
		return err
	}
	return nil
}

func validateOnlyKnownLegacyRelations(
	ctx context.Context,
	queryer schemaQueryer,
	includeMetadata bool,
) error {
	relations, err := schemaRelationNames(ctx, queryer)
	if err != nil {
		return err
	}
	allowed := append(slices.Clone(legacyTableFingerprint), legacySequenceNames...)
	allowed = append(allowed, "model_migrations", "supported_models")
	if includeMetadata {
		allowed = append(allowed, schemaMigrationTable)
	}
	for _, relation := range relations {
		if !slices.Contains(allowed, relation) {
			return fmt.Errorf("unexpected relation %q", relation)
		}
	}
	return nil
}

func validateCriticalSchemaShape(
	ctx context.Context,
	queryer schemaQueryer,
	version int64,
) error {
	for _, table := range legacyTableFingerprint {
		exists, err := tableExists(ctx, queryer, table)
		if err != nil {
			return fmt.Errorf("critical schema shape: %w", err)
		}
		if !exists {
			return fmt.Errorf("critical schema shape mismatch: required table %q is missing", table)
		}
	}
	if err := validateCriticalColumns(ctx, queryer, true, false); err != nil {
		return fmt.Errorf("critical schema shape mismatch: %w", err)
	}
	if err := validateCriticalKeys(ctx, queryer, true); err != nil {
		return fmt.Errorf("critical schema shape mismatch: %w", err)
	}
	if version >= 2 {
		matches, err := concurrentIndexDefinitionMatches(
			ctx,
			queryer,
			"idx_provider_earnings_job",
		)
		if err != nil {
			return fmt.Errorf("critical schema shape: inspect provider earnings index: %w", err)
		}
		if !matches {
			return errors.New("critical schema shape mismatch: idx_provider_earnings_job is not canonical")
		}
	}
	return nil
}

func validateCriticalColumns(
	ctx context.Context,
	queryer schemaQueryer,
	includeMetadata bool,
	onlyExisting bool,
) error {
	for _, required := range criticalColumnShapes {
		if required.Table == schemaMigrationTable && !includeMetadata {
			continue
		}
		exists, err := tableExists(ctx, queryer, required.Table)
		if err != nil {
			return err
		}
		if !exists && onlyExisting {
			continue
		}
		var (
			actualType string
			notNull    bool
		)
		err = queryer.QueryRow(ctx, `
			SELECT format_type(attribute.atttypid, attribute.atttypmod),
			       attribute.attnotnull
			FROM pg_attribute attribute
			JOIN pg_class relation ON relation.oid = attribute.attrelid
			JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
			WHERE namespace.nspname = COALESCE(
				NULLIF(current_setting('darkbloom.migration_schema', true), ''),
				current_schema()
			)
			  AND relation.relname = $1
			  AND relation.relkind IN ('r', 'p')
			  AND attribute.attname = $2
			  AND attribute.attnum > 0
			  AND NOT attribute.attisdropped`,
			required.Table,
			required.Column,
		).Scan(&actualType, &notNull)
		if errors.Is(err, pgx.ErrNoRows) {
			if onlyExisting {
				continue
			}
			return fmt.Errorf("required column %s.%s is missing", required.Table, required.Column)
		}
		if err != nil {
			return fmt.Errorf("inspect column %s.%s: %w", required.Table, required.Column, err)
		}
		if actualType != required.Type {
			return fmt.Errorf(
				"column %s.%s has type %s, want %s",
				required.Table,
				required.Column,
				actualType,
				required.Type,
			)
		}
		if required.NotNull && !notNull {
			return fmt.Errorf("column %s.%s must be NOT NULL", required.Table, required.Column)
		}
	}
	return nil
}

func validateCriticalKeys(
	ctx context.Context,
	queryer schemaQueryer,
	includeMetadata bool,
) error {
	for _, required := range criticalKeyShapes {
		if required.Table == schemaMigrationTable && !includeMetadata {
			continue
		}
		exists, err := tableExists(ctx, queryer, required.Table)
		if err != nil {
			return err
		}
		if !exists {
			continue
		}
		var matches bool
		err = queryer.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1
				FROM pg_constraint constraint_row
				JOIN pg_class relation ON relation.oid = constraint_row.conrelid
				JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
				WHERE namespace.nspname = COALESCE(
					NULLIF(current_setting('darkbloom.migration_schema', true), ''),
					current_schema()
				)
				  AND relation.relname = $1
				  AND constraint_row.contype = $2
				  AND ARRAY(
					SELECT attribute.attname::text
					FROM unnest(constraint_row.conkey)
					     WITH ORDINALITY AS key_column(attnum, ord)
					JOIN pg_attribute attribute
					  ON attribute.attrelid = relation.oid
					 AND attribute.attnum = key_column.attnum
					ORDER BY key_column.ord
				  ) = $3::text[]
			) OR (
				$2 = 'u' AND EXISTS (
					SELECT 1
					FROM pg_index index_row
					JOIN pg_class relation ON relation.oid = index_row.indrelid
					JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
					WHERE namespace.nspname = COALESCE(
						NULLIF(current_setting('darkbloom.migration_schema', true), ''),
						current_schema()
					)
					  AND relation.relname = $1
					  AND index_row.indisunique
					  AND index_row.indisvalid
					  AND index_row.indpred IS NULL
					  AND index_row.indexprs IS NULL
					  AND index_row.indnkeyatts = cardinality($3::text[])
					  AND index_row.indnatts = cardinality($3::text[])
					  AND ARRAY(
						SELECT attribute.attname::text
						FROM unnest(index_row.indkey)
						     WITH ORDINALITY AS key_column(attnum, ord)
						JOIN pg_attribute attribute
						  ON attribute.attrelid = relation.oid
						 AND attribute.attnum = key_column.attnum
						ORDER BY key_column.ord
					  ) = $3::text[]
				)
			)`,
			required.Table,
			required.Kind,
			required.Columns,
		).Scan(&matches)
		if err != nil {
			return fmt.Errorf("inspect key on %s: %w", required.Table, err)
		}
		if !matches {
			kind := "unique"
			if required.Kind == "p" {
				kind = "primary"
			}
			return fmt.Errorf(
				"table %s is missing %s key on (%s)",
				required.Table,
				kind,
				required.Columns,
			)
		}
	}
	return nil
}

func tableExists(ctx context.Context, queryer schemaQueryer, table string) (bool, error) {
	var exists bool
	err := queryer.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM pg_class relation
			JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
			WHERE namespace.nspname = COALESCE(
				NULLIF(current_setting('darkbloom.migration_schema', true), ''),
				current_schema()
			)
			  AND relation.relname = $1
			  AND relation.relkind IN ('r', 'p')
		)`,
		table,
	).Scan(&exists)
	if err != nil {
		return false, fmt.Errorf("inspect table %s: %w", table, err)
	}
	return exists, nil
}

func schemaRelationNames(ctx context.Context, queryer schemaQueryer) ([]string, error) {
	rows, err := queryer.Query(ctx, `
		SELECT relation.relname
		FROM pg_class relation
		JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
		WHERE namespace.nspname = COALESCE(
			NULLIF(current_setting('darkbloom.migration_schema', true), ''),
			current_schema()
		)
		  AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
		ORDER BY relation.relname`)
	if err != nil {
		return nil, fmt.Errorf("inspect schema relations: %w", err)
	}
	defer rows.Close()

	var tables []string
	for rows.Next() {
		var table string
		if err := rows.Scan(&table); err != nil {
			return nil, fmt.Errorf("scan schema relation: %w", err)
		}
		tables = append(tables, table)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate schema relations: %w", err)
	}
	return tables, nil
}
