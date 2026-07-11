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
	if err := backend.CheckRollbackSafe(ctx); err != nil {
		t.Fatalf("empty Rust schema v3: %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		INSERT INTO rust_coord.inference_jobs (
			job_id, request_id, reservation_id, reserve_operation_key,
			account_id, owner_epoch, state, reserved_total_micro_usd,
			reserved_withdrawable_micro_usd, reservation_pre_debited,
			request_deadline
		) VALUES (
			'10000000-0000-0000-0000-000000000001',
			'10000000-0000-0000-0000-000000000002',
			'10000000-0000-0000-0000-000000000003',
			'reserve:rollback', 'account:rollback', 1, 'running',
			0, 0, true, NOW() + INTERVAL '1 minute'
		)`); err == nil {
		t.Fatal("running job without frozen terms unexpectedly passed schema checks")
	}
	if _, err := backend.pool.Exec(ctx, `
		INSERT INTO rust_coord.inference_jobs (
			job_id, request_id, reservation_id, reserve_operation_key,
			account_id, owner_epoch, state, reserved_total_micro_usd,
			reserved_withdrawable_micro_usd, reservation_pre_debited,
			request_deadline
		) VALUES (
			'10000000-0000-0000-0000-000000000001',
			'10000000-0000-0000-0000-000000000002',
			'10000000-0000-0000-0000-000000000003',
			'reserve:rollback', 'account:rollback', 1, 'reserved',
			10, 4, true, NOW() + INTERVAL '1 minute'
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "inference_jobs") {
		t.Fatalf("active job guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.inference_jobs
		SET state = 'released', terminal_at = NOW(), updated_at = NOW()
		WHERE job_id = '10000000-0000-0000-0000-000000000001';
		INSERT INTO rust_coord.inference_attempts (
			attempt_id, job_id, provider_id, provider_process_generation_id,
			session_epoch, owner_epoch, permit_id, dispatch_nonce,
			request_digest, kind, state
		) VALUES (
			'10000000-0000-0000-0000-000000000004',
			'10000000-0000-0000-0000-000000000001',
			'10000000-0000-0000-0000-000000000005',
			'10000000-0000-0000-0000-000000000006',
			1, 1,
			'10000000-0000-0000-0000-000000000007',
			decode(repeat('11', 32), 'hex'),
			decode(repeat('12', 32), 'hex'),
			'primary', 'sent_unknown'
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "inference_attempts") {
		t.Fatalf("active attempt guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx,
		`UPDATE rust_coord.inference_attempts SET state = 'aborted', updated_at = NOW()`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err != nil {
		t.Fatalf("terminal job and attempt rejected: %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		INSERT INTO rust_coord.provider_terminals (
			terminal_id, job_id, attempt_id, provider_id,
			provider_process_generation_id, origin_session_epoch,
			terminal_digest, raw_terminal, outcome, prompt_tokens,
			completion_tokens, response_digest, rolling_digest,
			final_generated_tokens, provider_signature, owner_epoch
		) VALUES (
			'10000000-0000-0000-0000-000000000008',
			'10000000-0000-0000-0000-000000000001',
			'10000000-0000-0000-0000-000000000004',
			'10000000-0000-0000-0000-000000000005',
			'10000000-0000-0000-0000-000000000006',
			1, decode(repeat('13', 32), 'hex'), '{}', 'cancelled',
			0, 0, decode(repeat('14', 32), 'hex'),
			decode(repeat('15', 32), 'hex'), 0, decode('01', 'hex'), 1
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "provider_terminals") {
		t.Fatalf("pending terminal guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.provider_terminals
		SET status = 'released_reviewed', conflict = TRUE,
		    disposition_at = NOW(), updated_at = NOW();
		UPDATE rust_coord.inference_jobs
		SET state = 'released_reviewed', updated_at = NOW()
		WHERE job_id = '10000000-0000-0000-0000-000000000001';
		INSERT INTO rust_coord.financial_operations (
			operation_id, operation_key, operation_digest, kind, status,
			account_id, amount_total_micro_usd,
			amount_withdrawable_micro_usd, owner_epoch
		) VALUES (
			'10000000-0000-0000-0000-000000000009',
			'deposit:rollback', decode(repeat('16', 32), 'hex'),
			'deposit', 'pending', 'account:rollback', 10, 0, 1
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "financial_operations") {
		t.Fatalf("pending financial operation guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.financial_operations
		SET status = 'failed', completed_at = NOW(), updated_at = NOW();
		INSERT INTO rust_coord.external_events (
			external_event_id, source, event_id, event_kind, payload_digest,
			status, owner_epoch
		) VALUES (
			'10000000-0000-0000-0000-000000000010',
			'stripe', 'evt_rollback', 'checkout',
			decode(repeat('17', 32), 'hex'), 'pending', 1
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "external_events") {
		t.Fatalf("pending external event guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.external_events
		SET status = 'failed', processed_at = NOW(), updated_at = NOW();
		INSERT INTO rust_coord.outbox (
			outbox_id, operation_key, payload_digest, kind, status, owner_epoch
		) VALUES (
			'10000000-0000-0000-0000-000000000011',
			'outbox:rollback', decode(repeat('18', 32), 'hex'),
			'notification', 'pending', 1
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "outbox") {
		t.Fatalf("pending outbox guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.outbox SET status = 'failed', updated_at = NOW();
		INSERT INTO rust_coord.fee_allocations (
			allocation_id, operation_key, job_id, financial_operation_id,
			kind, source_account_id, beneficiary_account_id,
			amount_micro_usd, status, owner_epoch
		) VALUES (
			'10000000-0000-0000-0000-000000000012',
			'fee:rollback',
			'10000000-0000-0000-0000-000000000001',
			'10000000-0000-0000-0000-000000000009',
			'platform', 'account:rollback', 'platform', 1, 'pending', 1
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "fee_allocations") {
		t.Fatalf("pending fee allocation guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.fee_allocations
		SET status = 'projected', projected_at = NOW(), updated_at = NOW();
		INSERT INTO rust_coord.fee_projection_checkpoints (
			projection_name, status, owner_epoch, worker_owner, lease_until
		) VALUES (
			'legacy-balances', 'running', 1,
			'10000000-0000-0000-0000-000000000013', NOW() + INTERVAL '1 minute'
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "fee_projection_checkpoints") {
		t.Fatalf("active fee checkpoint guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		UPDATE rust_coord.fee_projection_checkpoints
		SET status = 'idle', worker_owner = NULL, lease_until = NULL, updated_at = NOW();
		INSERT INTO rust_coord.provider_hard_untrust_epochs (
			provider_id, hard_untrust_epoch, reason,
			evidence_digest, owner_epoch
		) VALUES (
			'10000000-0000-0000-0000-000000000005',
			1, 'rollback-test', decode(repeat('19', 32), 'hex'), 1
		)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err != nil {
		t.Fatalf("terminal Rust schema v3 state rejected: %v", err)
	}
	if _, err := backend.pool.Exec(ctx,
		`CREATE TABLE rust_coord.unrecognized_work (id BIGINT PRIMARY KEY)`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "unknown Rust schema v3 shape") {
		t.Fatalf("unknown Rust relation guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		DROP TABLE rust_coord.unrecognized_work;
		ALTER TABLE rust_coord.inference_jobs ADD COLUMN future_shape TEXT`); err != nil {
		t.Fatal(err)
	}
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "columns") {
		t.Fatalf("unknown Rust column shape guard error = %v", err)
	}
	if _, err := backend.pool.Exec(ctx, `
		ALTER TABLE rust_coord.inference_jobs DROP COLUMN future_shape;
		INSERT INTO rust_coord.schema_versions (
			version, minimum_public_schema_version, maximum_public_schema_version
		) VALUES (4, 6, 6)`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = backend.pool.Exec(context.Background(),
			`DELETE FROM rust_coord.schema_versions WHERE version = 4`)
	})
	if err := backend.CheckRollbackSafe(ctx); err == nil ||
		!strings.Contains(err.Error(), "unsupported Rust schema history") {
		t.Fatalf("newer Rust schema guard error = %v", err)
	}
}
