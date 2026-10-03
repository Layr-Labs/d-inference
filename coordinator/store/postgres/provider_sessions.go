package postgres

import (
	"context"
	"fmt"
	"time"
)

// OpenProviderSession records the start of a provider connection. Idempotent:
// ON CONFLICT DO NOTHING so a duplicate register, or an open that races behind a
// close (fast connect→disconnect), never creates a second or reopened row.
func (s *PostgresStore) OpenProviderSession(ctx context.Context, sessionID, serial, accountID string) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_sessions (session_id, serial_number, account_id)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (session_id) DO NOTHING`,
		sessionID, serial, accountID,
	)
	if err != nil {
		return fmt.Errorf("store: open provider session: %w", err)
	}
	return nil
}

// TouchProviderSession updates the open session's last_seen and backfills
// serial/account/provider_key if they were unknown at open time.
func (s *PostgresStore) TouchProviderSession(ctx context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_sessions
		    SET last_seen = $2,
		        serial_number = CASE WHEN serial_number = '' THEN $3 ELSE serial_number END,
		        account_id    = CASE WHEN account_id = ''    THEN $4 ELSE account_id    END,
		        provider_key  = CASE WHEN provider_key = ''  THEN $5 ELSE provider_key  END
		  WHERE session_id = $1 AND disconnected_at IS NULL`,
		sessionID, lastSeen, serial, accountID, providerKey,
	)
	if err != nil {
		return fmt.Errorf("store: touch provider session: %w", err)
	}
	return nil
}

// CloseProviderSession marks the session for sessionID as ended. Implemented as
// an upsert so it is correct regardless of whether the async OpenProviderSession
// has landed yet: if the row is missing (close raced ahead of open on a fast
// connect→disconnect) it inserts an already-closed row; if open, it closes it;
// if already closed, it leaves the original disconnect timestamp/reason intact.
func (s *PostgresStore) CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_sessions (session_id, connected_at, last_seen, disconnected_at, disconnect_reason)
		 VALUES ($1, $3, $3, $3, $2)
		 ON CONFLICT (session_id) DO UPDATE
		    SET disconnected_at = COALESCE(provider_sessions.disconnected_at, EXCLUDED.disconnected_at),
		        disconnect_reason = CASE WHEN provider_sessions.disconnected_at IS NULL
		                                 THEN EXCLUDED.disconnect_reason
		                                 ELSE provider_sessions.disconnect_reason END`,
		sessionID, reason, when,
	)
	if err != nil {
		return fmt.Errorf("store: close provider session: %w", err)
	}
	return nil
}

// CloseOpenProviderSessions closes open sessions whose last heartbeat predates
// staleBefore (orphaned by a prior coordinator process), setting disconnected_at
// to the last heartbeat seen. The last_seen < staleBefore fence prevents a
// blue-green deploy from truncating a session still live (and being touched) on
// the old instance over the shared DB — its last_seen stays fresh.
//
// Note: crash-path disconnected_at granularity is bounded by how often last_seen
// advances. Heartbeats touch it (TouchProviderSession), so the recorded
// disconnect can lag the true last-seen by at most the heartbeat interval.
func (s *PostgresStore) CloseOpenProviderSessions(ctx context.Context, staleBefore time.Time) (int, error) {
	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_sessions
		    SET disconnected_at = last_seen, disconnect_reason = 'coordinator_restart'
		  WHERE disconnected_at IS NULL AND last_seen < $1`,
		staleBefore,
	)
	if err != nil {
		return 0, fmt.Errorf("store: close open provider sessions: %w", err)
	}
	return int(tag.RowsAffected()), nil
}

// System profiler DDL (boot slice). Column names are the snake_case of the
// RequestProfileRecord / FleetSnapshotRow field names; nullability mirrors Go
// pointer-ness (pointer and json.RawMessage fields are nullable, everything
// else is NOT NULL with a zero default so zero values — 0, empty string,
// false — round-trip as themselves).
// Per-table autovacuum thresholds are tightened because both tables are
// insert-heavy with a rolling retention DELETE.
const (
	requestProfilesTableDDL = `CREATE TABLE IF NOT EXISTS request_profiles (
			id BIGSERIAL PRIMARY KEY,
			coord_request_id TEXT NOT NULL,
			request_id TEXT NOT NULL,
			attempt INT NOT NULL,
			backup_of TEXT NOT NULL DEFAULT '',
			winning BOOL NOT NULL DEFAULT FALSE,
			endpoint TEXT NOT NULL DEFAULT '',
			stream BOOL NOT NULL DEFAULT FALSE,
			model TEXT NOT NULL DEFAULT '',
			public_model TEXT NOT NULL DEFAULT '',
			provider_id TEXT NOT NULL DEFAULT '',
			provider_version TEXT NOT NULL DEFAULT '',
			chip_family TEXT NOT NULL DEFAULT '',
			kv_backend TEXT NOT NULL DEFAULT '',
			final_status TEXT NOT NULL DEFAULT '',
			error_reason TEXT NOT NULL DEFAULT '',
			terminal_cause TEXT NOT NULL DEFAULT '',
			client_outcome TEXT NOT NULL DEFAULT '',
			provider_outcome TEXT NOT NULL DEFAULT '',
			client_gone_phase TEXT NOT NULL DEFAULT '',
			first_content_budget_ms INT NOT NULL DEFAULT 0,
			admission_mode TEXT NOT NULL DEFAULT '',
			predictive_bypass TEXT NOT NULL DEFAULT '',
			reservation_ttft_ceiling_ms DOUBLE PRECISION,
			dispatch_budget_ms BIGINT,
			estimated_prompt_tokens INT NOT NULL DEFAULT 0,
			requested_max_tokens INT NOT NULL DEFAULT 0,
			requires_vision BOOL NOT NULL DEFAULT FALSE,
			has_tools BOOL NOT NULL DEFAULT FALSE,
			received_at TIMESTAMPTZ NOT NULL,

			auth_done_us BIGINT,
			ratelimit_done_us BIGINT,
			sealed_open_us BIGINT,
			handler_entry_us BIGINT,
			parsed_us BIGINT,
			reserved_us BIGINT,
			media_fetched_us BIGINT,
			preflight_done_us BIGINT,
			plan_done_us BIGINT,
			attempt_start_us BIGINT,
			reserve_lock_acquired_us BIGINT,
			reserve_done_us BIGINT,
			queued_us BIGINT,
			dequeued_us BIGINT,
			topup_done_us BIGINT,
			encrypted_us BIGINT,
			write_submitted_us BIGINT,
			write_dequeued_us BIGINT,
			write_done_us BIGINT,
			accepted_us BIGINT,
			first_chunk_ingress_us BIGINT,
			first_chunk_dequeued_us BIGINT,
			first_content_ingress_us BIGINT,
			first_content_us BIGINT,
			headers_written_us BIGINT,
			first_flush_us BIGINT,
			last_flush_us BIGINT,
			client_gone_us BIGINT,
			cancel_sent_us BIGINT,
			complete_ingress_us BIGINT,
			done_flushed_us BIGINT,
			finalized_us BIGINT,
			settle_db_us BIGINT,
			db_us BIGINT,
			db_calls INT NOT NULL DEFAULT 0,

			body_bytes INT NOT NULL DEFAULT 0,
			sealed_body_bytes INT NOT NULL DEFAULT 0,
			auth_kind TEXT NOT NULL DEFAULT '',
			auth_db_read BOOL NOT NULL DEFAULT FALSE,
			reserve_mode TEXT NOT NULL DEFAULT '',
			media_items INT NOT NULL DEFAULT 0,
			media_bytes BIGINT NOT NULL DEFAULT 0,
			preflight_outcome TEXT NOT NULL DEFAULT '',
			plan_outcome TEXT NOT NULL DEFAULT '',
			chunks_in INT NOT NULL DEFAULT 0,
			chunks_out INT NOT NULL DEFAULT 0,
			bytes_out BIGINT NOT NULL DEFAULT 0,
			decrypt_us_total BIGINT NOT NULL DEFAULT 0,
			max_chunk_gap_us BIGINT NOT NULL DEFAULT 0,
			held_preamble_chunks INT NOT NULL DEFAULT 0,
			client_write_err BOOL NOT NULL DEFAULT FALSE,
			attempts_total INT NOT NULL DEFAULT 0,
			failed_attempts INT NOT NULL DEFAULT 0,
			failed_attempts_us BIGINT NOT NULL DEFAULT 0,
			backup_launched BOOL NOT NULL DEFAULT FALSE,
			backup_won BOOL NOT NULL DEFAULT FALSE,
			transport_est_us BIGINT,
			slept_us BIGINT,
			timing_anomaly BOOL NOT NULL DEFAULT FALSE,

			candidate_set_size INT NOT NULL DEFAULT 0,
			scanned INT NOT NULL DEFAULT 0,
			gate_rejections JSONB,
			runner_up_provider_id TEXT NOT NULL DEFAULT '',
			runner_up_cost_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			near_tie_pool_size INT NOT NULL DEFAULT 0,
			selection_path TEXT NOT NULL DEFAULT '',
			best_idle_provider_id TEXT NOT NULL DEFAULT '',
			best_idle_ttft_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			predicted_ttft_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			raw_ttft_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			predicted_decode_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			snapshot_age_ms INT NOT NULL DEFAULT 0,
			pending_for_model INT NOT NULL DEFAULT 0,
			total_pending INT NOT NULL DEFAULT 0,
			capacity_rate_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			cache_discount_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			shadow_would_shed BOOL,
			shadow_idle_alternative BOOL,
			lock_wait_us BIGINT NOT NULL DEFAULT 0,
			scan_us BIGINT NOT NULL DEFAULT 0,
			admit_us BIGINT NOT NULL DEFAULT 0,
			preflight_us BIGINT NOT NULL DEFAULT 0,
			ttft_calibration_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
			prefill_decode_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
			queue_position_at_enqueue INT NOT NULL DEFAULT 0,
			queue_depth_at_enqueue INT NOT NULL DEFAULT 0,
			drain_trigger TEXT NOT NULL DEFAULT '',
			candidates JSONB,

			prov_total_us BIGINT,
			prov_first_delta_us BIGINT,
			prov_engine_submit_us BIGINT,
			prov_engine_admitted_us BIGINT,
			prov_prompt_prep_us BIGINT,
			prov_load_wait_us BIGINT,
			prov_load_cold BOOL,
			prov_running_at_admit INT,
			prov_waiting_at_admit INT,
			prov_kv_bytes_in_use_at_admit BIGINT,
			prov_cancel_stage TEXT NOT NULL DEFAULT '',
			eng_queue_wait_ns BIGINT,
			eng_first_token_ns BIGINT,
			eng_prompt_computed_ns BIGINT,
			eng_prefill_chunks INT,
			eng_decode_steps INT,
			eng_mtp_accepted INT,
			eng_finish_reason TEXT NOT NULL DEFAULT '',
			provider_profile JSONB,
			provider_profile_valid BOOL NOT NULL DEFAULT FALSE,
			provider_profile_invalid_reason TEXT NOT NULL DEFAULT '',
			provider_profile_consistent BOOL,

			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			UNIQUE (request_id, attempt)
		) WITH (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.01)`
	requestProfilesCreatedIndexDDL  = `CREATE INDEX IF NOT EXISTS idx_request_profiles_created ON request_profiles(created_at DESC)`
	requestProfilesCoordIndexDDL    = `CREATE INDEX IF NOT EXISTS idx_request_profiles_coord ON request_profiles(coord_request_id)`
	requestProfilesProviderIndexDDL = `CREATE INDEX IF NOT EXISTS idx_request_profiles_provider ON request_profiles(provider_id, created_at DESC)`

	fleetSnapshotsTableDDL = `CREATE TABLE IF NOT EXISTS fleet_snapshots (
			id BIGSERIAL PRIMARY KEY,
			sampled_at TIMESTAMPTZ NOT NULL,
			provider_id TEXT NOT NULL,
			model TEXT NOT NULL DEFAULT '',
			eligibility_reason TEXT NOT NULL DEFAULT '',
			slot_state TEXT NOT NULL DEFAULT '',
			num_running INT NOT NULL DEFAULT 0,
			num_waiting INT NOT NULL DEFAULT 0,
			queued_prefill_tokens INT NOT NULL DEFAULT 0,
			partial_prefill_rows INT NOT NULL DEFAULT 0,
			active_token_budget_used BIGINT NOT NULL DEFAULT 0,
			active_token_budget_max BIGINT NOT NULL DEFAULT 0,
			kv_bytes_in_use BIGINT NOT NULL DEFAULT 0,
			kv_bytes_capacity BIGINT NOT NULL DEFAULT 0,
			observed_decode_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			observed_prefill_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			isolated_prefill_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			ewma_initialized BOOL,
			max_concurrency INT NOT NULL DEFAULT 0,
			pending_count INT NOT NULL DEFAULT 0,
			effective_cap INT NOT NULL DEFAULT 0,
			cooldown_active BOOL NOT NULL DEFAULT FALSE,
			breaker_open BOOL NOT NULL DEFAULT FALSE,
			clamp_active BOOL NOT NULL DEFAULT FALSE,
			ejected BOOL NOT NULL DEFAULT FALSE,
			gpu_memory_active_gb DOUBLE PRECISION NOT NULL DEFAULT 0,
			gpu_memory_peak_gb DOUBLE PRECISION NOT NULL DEFAULT 0,
			free_for_load_gb DOUBLE PRECISION,
			memory_pressure DOUBLE PRECISION NOT NULL DEFAULT 0,
			cpu_usage DOUBLE PRECISION NOT NULL DEFAULT 0,
			thermal_state TEXT NOT NULL DEFAULT '',
			low_power_mode BOOL,
			memory_pressure_level TEXT NOT NULL DEFAULT '',
			steps_executed BIGINT NOT NULL DEFAULT 0,
			step_wall_ns_total BIGINT NOT NULL DEFAULT 0,
			decode_rows_total BIGINT NOT NULL DEFAULT 0,
			prefill_tokens_total BIGINT NOT NULL DEFAULT 0,
			mtp_rounds_total BIGINT NOT NULL DEFAULT 0,
			mtp_proposed_total BIGINT NOT NULL DEFAULT 0,
			mtp_accepted_total BIGINT NOT NULL DEFAULT 0,
			heartbeat_age_ms INT NOT NULL DEFAULT 0,
			wedge_suspected BOOL NOT NULL DEFAULT FALSE,
			eval_in_flight_ms BIGINT NOT NULL DEFAULT 0,
			requests_served BIGINT NOT NULL DEFAULT 0,
			tokens_generated BIGINT NOT NULL DEFAULT 0,
			cancellations_received BIGINT NOT NULL DEFAULT 0,
			cancellations_before_output BIGINT NOT NULL DEFAULT 0,
			cancellations_partial_complete BIGINT NOT NULL DEFAULT 0,
			generation_errors_after_output BIGINT NOT NULL DEFAULT 0,
			chunk_encryption_errors BIGINT NOT NULL DEFAULT 0,
			stream_closed_without_terminal BIGINT NOT NULL DEFAULT 0,
			cancel_during_model_load BIGINT NOT NULL DEFAULT 0,
			usage_gaps BIGINT NOT NULL DEFAULT 0,
			cancel_stage_pre_accept_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_pre_engine_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_prefill_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_decode_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_post_terminal_total BIGINT NOT NULL DEFAULT 0,
			tokens_after_cancel_total BIGINT NOT NULL DEFAULT 0,
			cancel_abort_ns_sum BIGINT NOT NULL DEFAULT 0,
			queue_depth_total INT NOT NULL DEFAULT 0,
			queue_depth_by_model JSONB,
			inflight_requests INT NOT NULL DEFAULT 0,
			reserve_lock_wait_p95_us BIGINT NOT NULL DEFAULT 0,
			profile_sink_depth INT NOT NULL DEFAULT 0,
			profile_sink_dropped_total BIGINT NOT NULL DEFAULT 0,
			route_sink_dropped_total BIGINT NOT NULL DEFAULT 0,
			unknown_request_frames_total BIGINT NOT NULL DEFAULT 0,
			goroutines INT NOT NULL DEFAULT 0,
			provider_version TEXT NOT NULL DEFAULT '',
			model_vision BOOL NOT NULL DEFAULT FALSE,
			template_render_ok BOOL
		) WITH (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.01)`
	fleetSnapshotsSampledIndexDDL  = `CREATE INDEX IF NOT EXISTS idx_fleet_snapshots_sampled ON fleet_snapshots(sampled_at DESC)`
	fleetSnapshotsProviderIndexDDL = `CREATE INDEX IF NOT EXISTS idx_fleet_snapshots_provider ON fleet_snapshots(provider_id, sampled_at DESC)`
)
