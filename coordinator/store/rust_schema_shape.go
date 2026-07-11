package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

var rustSchemaV2Tables = []string{
	"external_events",
	"fee_allocations",
	"fee_projection_checkpoints",
	"financial_operations",
	"inference_attempts",
	"inference_jobs",
	"outbox",
	"provider_hard_untrust_epochs",
	"provider_terminals",
	"schema_versions",
}

var rustSchemaV2ColumnNames = map[string][]string{
	"schema_versions": {
		"version", "minimum_public_schema_version",
		"maximum_public_schema_version", "applied_at",
	},
	"inference_jobs": {
		"job_id", "request_id", "reservation_id", "reserve_operation_key",
		"account_id", "api_key_id", "owner_epoch", "version", "state",
		"reserved_total_micro_usd", "reserved_withdrawable_micro_usd",
		"reservation_pre_debited", "concrete_model", "public_model",
		"pricing_version", "rounding_version", "billable_input_tokens",
		"bounded_output_tokens", "provider_id", "provider_account_id",
		"platform_account_id", "referral_account_id",
		"provider_payout_micro_usd", "platform_fee_micro_usd",
		"referral_reward_micro_usd", "referral_share_ppm", "request_digest",
		"accepted_chunk_sequence", "accepted_cumulative_tokens",
		"first_content_deadline", "request_deadline", "outcome", "error_class",
		"usage_prompt_tokens", "usage_completion_tokens",
		"usage_reasoning_tokens", "response_digest", "worker_owner",
		"lease_until", "created_at", "updated_at", "terminal_at",
	},
	"inference_attempts": {
		"attempt_id", "job_id", "provider_id",
		"provider_process_generation_id", "session_epoch", "owner_epoch",
		"lease_id", "permit_id", "dispatch_nonce", "request_digest", "kind",
		"state", "version", "worker_owner", "lease_until", "created_at",
		"updated_at",
	},
	"provider_terminals": {
		"terminal_id", "job_id", "attempt_id", "provider_id",
		"provider_process_generation_id", "origin_session_epoch",
		"terminal_digest", "raw_terminal", "outcome", "error_class",
		"prompt_tokens", "completion_tokens", "reasoning_tokens",
		"response_digest", "rolling_digest", "final_generated_tokens",
		"provider_signature", "status", "conflict", "received_count",
		"owner_epoch", "version", "worker_owner", "lease_until", "received_at",
		"updated_at", "disposition_at",
	},
	"financial_operations": {
		"operation_id", "operation_key", "operation_digest", "kind", "status",
		"job_id", "terminal_id", "account_id", "counterparty_account_id",
		"amount_total_micro_usd", "amount_withdrawable_micro_usd", "result",
		"owner_epoch", "version", "worker_owner", "lease_until", "created_at",
		"updated_at", "completed_at",
	},
	"external_events": {
		"external_event_id", "source", "event_id", "event_kind",
		"payload_digest", "payload", "status", "financial_operation_id",
		"owner_epoch", "version", "worker_owner", "lease_until", "received_at",
		"updated_at", "processed_at",
	},
	"outbox": {
		"outbox_id", "operation_key", "payload_digest", "kind", "status",
		"job_id", "financial_operation_id", "payload", "attempts",
		"max_attempts", "next_attempt_at", "owner_epoch", "version",
		"worker_owner", "lease_until", "created_at", "updated_at",
		"delivered_at",
	},
	"fee_allocations": {
		"allocation_id", "allocation_sequence", "operation_key", "job_id",
		"financial_operation_id", "kind", "source_account_id",
		"beneficiary_account_id", "amount_micro_usd", "status", "owner_epoch",
		"version", "worker_owner", "lease_until", "created_at", "updated_at",
		"projected_at",
	},
	"fee_projection_checkpoints": {
		"projection_name", "last_allocation_sequence", "last_allocation_id",
		"status", "owner_epoch", "version", "worker_owner", "lease_until",
		"created_at", "updated_at",
	},
	"provider_hard_untrust_epochs": {
		"provider_id", "hard_untrust_epoch", "reason", "evidence_digest",
		"owner_epoch", "version", "created_at", "updated_at",
	},
}

var rustSchemaV2Columns = []columnShapeRequirement{
	{Table: "inference_jobs", Column: "job_id", Type: "uuid", NotNull: true},
	{Table: "inference_jobs", Column: "request_id", Type: "uuid", NotNull: true},
	{Table: "inference_jobs", Column: "reservation_id", Type: "uuid", NotNull: true},
	{Table: "inference_jobs", Column: "reserve_operation_key", Type: "text", NotNull: true},
	{Table: "inference_jobs", Column: "state", Type: "text", NotNull: true},
	{Table: "inference_jobs", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "inference_jobs", Column: "version", Type: "bigint", NotNull: true},
	{Table: "inference_jobs", Column: "reserved_total_micro_usd", Type: "bigint", NotNull: true},
	{Table: "inference_jobs", Column: "reserved_withdrawable_micro_usd", Type: "bigint", NotNull: true},
	{Table: "inference_jobs", Column: "reservation_pre_debited", Type: "boolean", NotNull: true},
	{Table: "inference_jobs", Column: "request_digest", Type: "bytea", NotNull: false},
	{Table: "inference_jobs", Column: "worker_owner", Type: "uuid", NotNull: false},
	{Table: "inference_jobs", Column: "lease_until", Type: "timestamp with time zone", NotNull: false},
	{Table: "inference_attempts", Column: "attempt_id", Type: "uuid", NotNull: true},
	{Table: "inference_attempts", Column: "job_id", Type: "uuid", NotNull: true},
	{Table: "inference_attempts", Column: "provider_id", Type: "uuid", NotNull: true},
	{Table: "inference_attempts", Column: "provider_process_generation_id", Type: "uuid", NotNull: true},
	{Table: "inference_attempts", Column: "lease_id", Type: "uuid", NotNull: false},
	{Table: "inference_attempts", Column: "request_digest", Type: "bytea", NotNull: true},
	{Table: "inference_attempts", Column: "state", Type: "text", NotNull: true},
	{Table: "inference_attempts", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "inference_attempts", Column: "version", Type: "bigint", NotNull: true},
	{Table: "provider_terminals", Column: "terminal_id", Type: "uuid", NotNull: true},
	{Table: "provider_terminals", Column: "terminal_digest", Type: "bytea", NotNull: true},
	{Table: "provider_terminals", Column: "status", Type: "text", NotNull: true},
	{Table: "provider_terminals", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "provider_terminals", Column: "version", Type: "bigint", NotNull: true},
	{Table: "financial_operations", Column: "operation_id", Type: "uuid", NotNull: true},
	{Table: "financial_operations", Column: "operation_key", Type: "text", NotNull: true},
	{Table: "financial_operations", Column: "operation_digest", Type: "bytea", NotNull: true},
	{Table: "financial_operations", Column: "status", Type: "text", NotNull: true},
	{Table: "financial_operations", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "financial_operations", Column: "version", Type: "bigint", NotNull: true},
	{Table: "external_events", Column: "external_event_id", Type: "uuid", NotNull: true},
	{Table: "external_events", Column: "payload_digest", Type: "bytea", NotNull: true},
	{Table: "external_events", Column: "status", Type: "text", NotNull: true},
	{Table: "external_events", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "external_events", Column: "version", Type: "bigint", NotNull: true},
	{Table: "outbox", Column: "outbox_id", Type: "uuid", NotNull: true},
	{Table: "outbox", Column: "operation_key", Type: "text", NotNull: true},
	{Table: "outbox", Column: "payload_digest", Type: "bytea", NotNull: true},
	{Table: "outbox", Column: "status", Type: "text", NotNull: true},
	{Table: "outbox", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "outbox", Column: "version", Type: "bigint", NotNull: true},
	{Table: "fee_allocations", Column: "allocation_id", Type: "uuid", NotNull: true},
	{Table: "fee_allocations", Column: "allocation_sequence", Type: "bigint", NotNull: true},
	{Table: "fee_allocations", Column: "operation_key", Type: "text", NotNull: true},
	{Table: "fee_allocations", Column: "beneficiary_account_id", Type: "text", NotNull: true},
	{Table: "fee_allocations", Column: "status", Type: "text", NotNull: true},
	{Table: "fee_allocations", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "fee_allocations", Column: "version", Type: "bigint", NotNull: true},
	{Table: "fee_projection_checkpoints", Column: "projection_name", Type: "text", NotNull: true},
	{Table: "fee_projection_checkpoints", Column: "last_allocation_sequence", Type: "bigint", NotNull: true},
	{Table: "fee_projection_checkpoints", Column: "status", Type: "text", NotNull: true},
	{Table: "fee_projection_checkpoints", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "fee_projection_checkpoints", Column: "version", Type: "bigint", NotNull: true},
	{Table: "provider_hard_untrust_epochs", Column: "provider_id", Type: "uuid", NotNull: true},
	{Table: "provider_hard_untrust_epochs", Column: "hard_untrust_epoch", Type: "bigint", NotNull: true},
	{Table: "provider_hard_untrust_epochs", Column: "evidence_digest", Type: "bytea", NotNull: true},
	{Table: "provider_hard_untrust_epochs", Column: "owner_epoch", Type: "bigint", NotNull: true},
	{Table: "provider_hard_untrust_epochs", Column: "version", Type: "bigint", NotNull: true},
}

var rustSchemaV2Keys = []keyShapeRequirement{
	{Table: "inference_jobs", Kind: "p", Columns: []string{"job_id"}},
	{Table: "inference_jobs", Kind: "u", Columns: []string{"request_id"}},
	{Table: "inference_jobs", Kind: "u", Columns: []string{"reservation_id"}},
	{Table: "inference_jobs", Kind: "u", Columns: []string{"reserve_operation_key"}},
	{Table: "inference_attempts", Kind: "p", Columns: []string{"attempt_id"}},
	{Table: "provider_terminals", Kind: "p", Columns: []string{"terminal_id"}},
	{Table: "provider_terminals", Kind: "u", Columns: []string{"terminal_digest"}},
	{Table: "financial_operations", Kind: "p", Columns: []string{"operation_id"}},
	{Table: "financial_operations", Kind: "u", Columns: []string{"operation_key"}},
	{Table: "financial_operations", Kind: "u", Columns: []string{"operation_digest"}},
	{Table: "external_events", Kind: "p", Columns: []string{"external_event_id"}},
	{Table: "external_events", Kind: "u", Columns: []string{"source", "event_id"}},
	{Table: "outbox", Kind: "p", Columns: []string{"outbox_id"}},
	{Table: "outbox", Kind: "u", Columns: []string{"operation_key"}},
	{Table: "fee_allocations", Kind: "p", Columns: []string{"allocation_id"}},
	{Table: "fee_allocations", Kind: "u", Columns: []string{"operation_key"}},
	{Table: "fee_allocations", Kind: "u", Columns: []string{"job_id", "kind"}},
	{Table: "fee_projection_checkpoints", Kind: "p", Columns: []string{"projection_name"}},
	{Table: "provider_hard_untrust_epochs", Kind: "p", Columns: []string{"provider_id"}},
}

type rustStatusShapeRequirement struct {
	Table      string
	Constraint string
	Column     string
	Allowed    []string
}

type rustForeignKeyShapeRequirement struct {
	Table             string
	Constraint        string
	Columns           []string
	ReferencedTable   string
	ReferencedColumns []string
}

var rustSchemaV2ForeignKeys = []rustForeignKeyShapeRequirement{
	{
		Table:             "inference_attempts",
		Constraint:        "inference_attempts_job_fk",
		Columns:           []string{"job_id"},
		ReferencedTable:   "inference_jobs",
		ReferencedColumns: []string{"job_id"},
	},
	{
		Table:      "provider_terminals",
		Constraint: "provider_terminals_attempt_fk",
		Columns: []string{
			"job_id", "attempt_id", "provider_id",
			"provider_process_generation_id", "origin_session_epoch",
		},
		ReferencedTable: "inference_attempts",
		ReferencedColumns: []string{
			"job_id", "attempt_id", "provider_id",
			"provider_process_generation_id", "session_epoch",
		},
	},
	{
		Table:             "financial_operations",
		Constraint:        "financial_operations_job_fk",
		Columns:           []string{"job_id"},
		ReferencedTable:   "inference_jobs",
		ReferencedColumns: []string{"job_id"},
	},
	{
		Table:             "financial_operations",
		Constraint:        "financial_operations_terminal_fk",
		Columns:           []string{"terminal_id"},
		ReferencedTable:   "provider_terminals",
		ReferencedColumns: []string{"terminal_id"},
	},
	{
		Table:             "external_events",
		Constraint:        "external_events_financial_operation_fk",
		Columns:           []string{"financial_operation_id"},
		ReferencedTable:   "financial_operations",
		ReferencedColumns: []string{"operation_id"},
	},
	{
		Table:             "outbox",
		Constraint:        "outbox_job_fk",
		Columns:           []string{"job_id"},
		ReferencedTable:   "inference_jobs",
		ReferencedColumns: []string{"job_id"},
	},
	{
		Table:             "outbox",
		Constraint:        "outbox_financial_operation_fk",
		Columns:           []string{"financial_operation_id"},
		ReferencedTable:   "financial_operations",
		ReferencedColumns: []string{"operation_id"},
	},
	{
		Table:             "fee_allocations",
		Constraint:        "fee_allocations_job_fk",
		Columns:           []string{"job_id"},
		ReferencedTable:   "inference_jobs",
		ReferencedColumns: []string{"job_id"},
	},
	{
		Table:             "fee_allocations",
		Constraint:        "fee_allocations_financial_operation_fk",
		Columns:           []string{"financial_operation_id"},
		ReferencedTable:   "financial_operations",
		ReferencedColumns: []string{"operation_id"},
	},
	{
		Table:           "fee_projection_checkpoints",
		Constraint:      "fee_projection_checkpoints_allocation_fk",
		Columns:         []string{"last_allocation_sequence", "last_allocation_id"},
		ReferencedTable: "fee_allocations",
		ReferencedColumns: []string{
			"allocation_sequence",
			"allocation_id",
		},
	},
}

var rustSchemaV2StatusShapes = []rustStatusShapeRequirement{
	{
		Table:      "inference_jobs",
		Constraint: "inference_jobs_state_check",
		Column:     "state",
		Allowed: []string{
			"prepared", "preparing", "released", "released_reviewed",
			"reserved", "review_pending", "running", "settled",
			"settled_reviewed", "start_authorized",
		},
	},
	{
		Table:      "inference_attempts",
		Constraint: "inference_attempts_state_check",
		Column:     "state",
		Allowed: []string{
			"aborted", "acknowledged", "prepared", "queued_to_socket",
			"sent_unknown", "started", "terminal_recorded",
		},
	},
	{
		Table:      "provider_terminals",
		Constraint: "provider_terminals_status_check",
		Column:     "status",
		Allowed: []string{
			"conflict", "duplicate", "late", "pending", "rejected", "released",
			"released_reviewed", "settled", "settled_reviewed",
		},
	},
	{
		Table:      "financial_operations",
		Constraint: "financial_operations_status_check",
		Column:     "status",
		Allowed:    []string{"applied", "failed", "pending", "released"},
	},
	{
		Table:      "external_events",
		Constraint: "external_events_status_check",
		Column:     "status",
		Allowed:    []string{"applied", "failed", "ignored", "pending", "processing", "rejected"},
	},
	{
		Table:      "outbox",
		Constraint: "outbox_status_check",
		Column:     "status",
		Allowed:    []string{"cancelled", "delivered", "failed", "pending", "processing"},
	},
	{
		Table:      "fee_allocations",
		Constraint: "fee_allocations_status_check",
		Column:     "status",
		Allowed:    []string{"cancelled", "failed", "pending", "processing", "projected"},
	},
	{
		Table:      "fee_projection_checkpoints",
		Constraint: "fee_projection_checkpoints_status_check",
		Column:     "status",
		Allowed:    []string{"failed", "idle", "running"},
	},
}

var quotedCheckValuePattern = regexp.MustCompile(`'([^']*)'::text`)

func validateRustSchemaV2Shape(ctx context.Context, queryer schemaQueryer) error {
	if err := validateRustSchemaHistory(ctx, queryer); err != nil {
		return err
	}
	if err := validateExactRustTables(ctx, queryer); err != nil {
		return err
	}
	if err := validateExactRustColumns(ctx, queryer); err != nil {
		return err
	}
	if err := validateRustColumns(ctx, queryer); err != nil {
		return err
	}
	if err := validateRustKeys(ctx, queryer); err != nil {
		return err
	}
	if err := validateRustForeignKeys(ctx, queryer); err != nil {
		return err
	}
	if err := validateRustStatusShapes(ctx, queryer); err != nil {
		return err
	}
	return nil
}

func validateExactRustColumns(ctx context.Context, queryer schemaQueryer) error {
	for table, want := range rustSchemaV2ColumnNames {
		rows, err := queryer.Query(ctx, `
			SELECT attribute.attname
			FROM pg_attribute attribute
			JOIN pg_class relation ON relation.oid = attribute.attrelid
			JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
			WHERE namespace.nspname = 'rust_coord'
			  AND relation.relname = $1
			  AND relation.relkind IN ('r', 'p')
			  AND attribute.attnum > 0
			  AND NOT attribute.attisdropped
			ORDER BY attribute.attnum`,
			table,
		)
		if err != nil {
			return fmt.Errorf("inspect columns on rust_coord.%s: %w", table, err)
		}
		var got []string
		for rows.Next() {
			var column string
			if err := rows.Scan(&column); err != nil {
				rows.Close()
				return fmt.Errorf("scan column on rust_coord.%s: %w", table, err)
			}
			got = append(got, column)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return fmt.Errorf("iterate columns on rust_coord.%s: %w", table, err)
		}
		rows.Close()
		if !slices.Equal(got, want) {
			return fmt.Errorf(
				"rust_coord.%s columns = %v, want exactly %v",
				table,
				got,
				want,
			)
		}
	}
	return nil
}

func validateRustSchemaHistory(ctx context.Context, queryer schemaQueryer) error {
	rows, err := queryer.Query(ctx, `
		SELECT version, minimum_public_schema_version, maximum_public_schema_version
		FROM rust_coord.schema_versions
		ORDER BY version`)
	if err != nil {
		return fmt.Errorf("inspect rust_coord schema history: %w", err)
	}
	defer rows.Close()
	type compatibility struct {
		version int64
		minimum int64
		maximum int64
	}
	var got []compatibility
	for rows.Next() {
		var item compatibility
		if err := rows.Scan(&item.version, &item.minimum, &item.maximum); err != nil {
			return fmt.Errorf("scan rust_coord schema history: %w", err)
		}
		got = append(got, item)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate rust_coord schema history: %w", err)
	}
	want := []compatibility{{1, 3, 3}, {2, 4, 4}}
	if !slices.Equal(got, want) {
		return fmt.Errorf("rust_coord schema history = %v, want %v", got, want)
	}
	return nil
}

func validateExactRustTables(ctx context.Context, queryer schemaQueryer) error {
	rows, err := queryer.Query(ctx, `
		SELECT relation.relname
		FROM pg_class relation
		JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
		WHERE namespace.nspname = 'rust_coord'
		  AND relation.relkind IN ('r', 'p')
		ORDER BY relation.relname`)
	if err != nil {
		return fmt.Errorf("inspect rust_coord tables: %w", err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var table string
		if err := rows.Scan(&table); err != nil {
			return fmt.Errorf("scan rust_coord table: %w", err)
		}
		got = append(got, table)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate rust_coord tables: %w", err)
	}
	if !slices.Equal(got, rustSchemaV2Tables) {
		return fmt.Errorf("rust_coord tables = %v, want exactly %v", got, rustSchemaV2Tables)
	}
	return nil
}

func validateRustColumns(ctx context.Context, queryer schemaQueryer) error {
	for _, required := range rustSchemaV2Columns {
		var (
			actualType string
			notNull    bool
		)
		err := queryer.QueryRow(ctx, `
			SELECT format_type(attribute.atttypid, attribute.atttypmod),
			       attribute.attnotnull
			FROM pg_attribute attribute
			JOIN pg_class relation ON relation.oid = attribute.attrelid
			JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
			WHERE namespace.nspname = 'rust_coord'
			  AND relation.relname = $1
			  AND relation.relkind IN ('r', 'p')
			  AND attribute.attname = $2
			  AND attribute.attnum > 0
			  AND NOT attribute.attisdropped`,
			required.Table,
			required.Column,
		).Scan(&actualType, &notNull)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("required column rust_coord.%s.%s is missing", required.Table, required.Column)
		}
		if err != nil {
			return fmt.Errorf("inspect column rust_coord.%s.%s: %w", required.Table, required.Column, err)
		}
		if actualType != required.Type {
			return fmt.Errorf(
				"column rust_coord.%s.%s has type %s, want %s",
				required.Table,
				required.Column,
				actualType,
				required.Type,
			)
		}
		if required.NotNull && !notNull {
			return fmt.Errorf("column rust_coord.%s.%s must be NOT NULL", required.Table, required.Column)
		}
	}
	return nil
}

func validateRustKeys(ctx context.Context, queryer schemaQueryer) error {
	for _, required := range rustSchemaV2Keys {
		var matches bool
		err := queryer.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1
				FROM pg_constraint constraint_row
				JOIN pg_class relation ON relation.oid = constraint_row.conrelid
				JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
				WHERE namespace.nspname = 'rust_coord'
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
			)`,
			required.Table,
			required.Kind,
			required.Columns,
		).Scan(&matches)
		if err != nil {
			return fmt.Errorf("inspect key on rust_coord.%s: %w", required.Table, err)
		}
		if !matches {
			return fmt.Errorf(
				"table rust_coord.%s is missing key on (%s)",
				required.Table,
				strings.Join(required.Columns, ", "),
			)
		}
	}
	return nil
}

func validateRustForeignKeys(ctx context.Context, queryer schemaQueryer) error {
	for _, required := range rustSchemaV2ForeignKeys {
		var matches bool
		err := queryer.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1
				FROM pg_constraint constraint_row
				JOIN pg_class relation ON relation.oid = constraint_row.conrelid
				JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
				JOIN pg_class referenced_relation
				  ON referenced_relation.oid = constraint_row.confrelid
				JOIN pg_namespace referenced_namespace
				  ON referenced_namespace.oid = referenced_relation.relnamespace
				WHERE namespace.nspname = 'rust_coord'
				  AND relation.relname = $1
				  AND constraint_row.conname = $2
				  AND constraint_row.contype = 'f'
				  AND constraint_row.convalidated
				  AND constraint_row.confdeltype = 'r'
				  AND referenced_namespace.nspname = 'rust_coord'
				  AND referenced_relation.relname = $3
				  AND ARRAY(
					SELECT attribute.attname::text
					FROM unnest(constraint_row.conkey)
					     WITH ORDINALITY AS key_column(attnum, ord)
					JOIN pg_attribute attribute
					  ON attribute.attrelid = relation.oid
					 AND attribute.attnum = key_column.attnum
					ORDER BY key_column.ord
				  ) = $4::text[]
				  AND ARRAY(
					SELECT attribute.attname::text
					FROM unnest(constraint_row.confkey)
					     WITH ORDINALITY AS key_column(attnum, ord)
					JOIN pg_attribute attribute
					  ON attribute.attrelid = referenced_relation.oid
					 AND attribute.attnum = key_column.attnum
					ORDER BY key_column.ord
				  ) = $5::text[]
			)`,
			required.Table,
			required.Constraint,
			required.ReferencedTable,
			required.Columns,
			required.ReferencedColumns,
		).Scan(&matches)
		if err != nil {
			return fmt.Errorf(
				"inspect foreign key rust_coord.%s.%s: %w",
				required.Table,
				required.Constraint,
				err,
			)
		}
		if !matches {
			return fmt.Errorf(
				"foreign key rust_coord.%s.%s is not canonical",
				required.Table,
				required.Constraint,
			)
		}
	}
	return nil
}

func validateRustStatusShapes(ctx context.Context, queryer schemaQueryer) error {
	for _, required := range rustSchemaV2StatusShapes {
		var (
			definition string
			validated  bool
		)
		err := queryer.QueryRow(ctx, `
			SELECT pg_get_constraintdef(constraint_row.oid, true),
			       constraint_row.convalidated
			FROM pg_constraint constraint_row
			JOIN pg_class relation ON relation.oid = constraint_row.conrelid
			JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
			WHERE namespace.nspname = 'rust_coord'
			  AND relation.relname = $1
			  AND constraint_row.conname = $2
			  AND constraint_row.contype = 'c'`,
			required.Table,
			required.Constraint,
		).Scan(&definition, &validated)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf(
				"required status constraint rust_coord.%s.%s is missing",
				required.Table,
				required.Constraint,
			)
		}
		if err != nil {
			return fmt.Errorf(
				"inspect status constraint rust_coord.%s.%s: %w",
				required.Table,
				required.Constraint,
				err,
			)
		}
		if !validated || !strings.Contains(definition, required.Column) {
			return fmt.Errorf(
				"status constraint rust_coord.%s.%s is not canonical",
				required.Table,
				required.Constraint,
			)
		}
		matches := quotedCheckValuePattern.FindAllStringSubmatch(definition, -1)
		actual := make([]string, 0, len(matches))
		for _, match := range matches {
			actual = append(actual, match[1])
		}
		sort.Strings(actual)
		if !slices.Equal(actual, required.Allowed) {
			return fmt.Errorf(
				"status constraint rust_coord.%s.%s allows %v, want %v",
				required.Table,
				required.Constraint,
				actual,
				required.Allowed,
			)
		}
	}
	return nil
}
