--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: clear_legacy_cache_affinity_key(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_legacy_cache_affinity_key() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN
	NEW.cache_affinity_key := '';
	RETURN NEW;
END $$;


--
-- Name: clear_provider_log_report_serial(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_provider_log_report_serial() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN
	NEW.serial_number := '';
	RETURN NEW;
END $$;


--
-- Name: update_model_demand_hourly(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_model_demand_hourly() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.outcome=NEW.outcome AND (OLD.http_status=429)=(NEW.http_status=429) THEN RETURN NEW; END IF;
 INSERT INTO model_demand_hourly (hour,model,consumer_hash,requests,completed,capacity_rejected,latency_rejected,timed_out,failed,cancelled,unknown,excluded,http_429)
 VALUES (date_trunc('hour',NEW.received_at,'UTC'),NEW.model,NEW.consumer_hash,
 1-CASE WHEN TG_OP='UPDATE' THEN 1 ELSE 0 END,
 (NEW.outcome='completed')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='completed')::integer ELSE 0 END,
 (NEW.outcome='capacity_rejected')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='capacity_rejected')::integer ELSE 0 END,
 (NEW.outcome='latency_rejected')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='latency_rejected')::integer ELSE 0 END,
 (NEW.outcome='timed_out')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='timed_out')::integer ELSE 0 END,
 (NEW.outcome='failed')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='failed')::integer ELSE 0 END,
 (NEW.outcome='cancelled')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='cancelled')::integer ELSE 0 END,
 (NEW.outcome='unknown')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='unknown')::integer ELSE 0 END,
 (NEW.outcome='excluded')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='excluded')::integer ELSE 0 END,
 (NEW.http_status=429 AND NEW.outcome<>'excluded')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.http_status=429 AND OLD.outcome<>'excluded')::integer ELSE 0 END)
 ON CONFLICT (hour,model,consumer_hash) DO UPDATE SET
 requests=model_demand_hourly.requests+EXCLUDED.requests,
 completed=model_demand_hourly.completed+EXCLUDED.completed,
 capacity_rejected=model_demand_hourly.capacity_rejected+EXCLUDED.capacity_rejected,
 latency_rejected=model_demand_hourly.latency_rejected+EXCLUDED.latency_rejected,
 timed_out=model_demand_hourly.timed_out+EXCLUDED.timed_out,
 failed=model_demand_hourly.failed+EXCLUDED.failed,
 cancelled=model_demand_hourly.cancelled+EXCLUDED.cancelled,
 unknown=model_demand_hourly.unknown+EXCLUDED.unknown,
 excluded=model_demand_hourly.excluded+EXCLUDED.excluded,
 http_429=model_demand_hourly.http_429+EXCLUDED.http_429;
 RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    key_hash text NOT NULL,
    raw_prefix text NOT NULL,
    owner_account_id text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    active boolean DEFAULT true NOT NULL,
    id text DEFAULT ''::text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    limit_micro_usd bigint,
    limit_reset text DEFAULT 'none'::text NOT NULL,
    rpm_limit bigint,
    itpm_limit bigint,
    otpm_limit bigint,
    allowed_models text DEFAULT ''::text NOT NULL,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    self_route_only boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: app_attest_build_qualifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_build_qualifications (
    binary_hash text NOT NULL,
    record jsonb NOT NULL,
    CONSTRAINT app_attest_build_qualifications_binary_hash_check CHECK ((binary_hash ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: app_attest_enrollments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_enrollments (
    id text NOT NULL,
    owner text NOT NULL,
    key_id text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    context jsonb NOT NULL
);


--
-- Name: app_attest_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_evidence (
    id text NOT NULL,
    session_id text NOT NULL,
    key_id text NOT NULL,
    received_at timestamp with time zone NOT NULL,
    action text NOT NULL,
    sha256 text NOT NULL,
    context jsonb NOT NULL,
    outcome text DEFAULT 'pending'::text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    completed_at timestamp with time zone
);


--
-- Name: app_attest_evidence_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_evidence_blobs (
    evidence_id text NOT NULL,
    proof_field text NOT NULL,
    proof bytea NOT NULL
);


--
-- Name: app_attest_key_revocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_key_revocations (
    key_id text NOT NULL,
    account_id text NOT NULL,
    reason text NOT NULL,
    revoked_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_attest_key_rotations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_key_rotations (
    key_id text NOT NULL,
    machine_id text NOT NULL,
    account_id text NOT NULL,
    requested_at timestamp with time zone NOT NULL,
    failures integer NOT NULL,
    reason text NOT NULL
);


--
-- Name: app_attest_receipt_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_receipt_blobs (
    receipt_id text NOT NULL,
    body bytea NOT NULL,
    response_body bytea NOT NULL
);


--
-- Name: app_attest_receipt_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_receipt_jobs (
    key_id text NOT NULL,
    receipt_id text NOT NULL,
    next_at timestamp with time zone NOT NULL,
    lease_until timestamp with time zone,
    attempts bigint DEFAULT 0 NOT NULL
);


--
-- Name: app_attest_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_receipts (
    id text NOT NULL,
    key_id text NOT NULL,
    evidence_id text NOT NULL,
    parent_id text NOT NULL,
    received_at timestamp with time zone NOT NULL,
    outcome text NOT NULL,
    http_status integer NOT NULL,
    details jsonb NOT NULL,
    context jsonb NOT NULL,
    next_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: app_attest_shadow_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_shadow_events (
    id text NOT NULL,
    session_id text NOT NULL,
    observed_at timestamp with time zone NOT NULL,
    stage text NOT NULL,
    outcome text NOT NULL,
    fields jsonb NOT NULL
);


--
-- Name: app_attest_shadow_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_attest_shadow_keys (
    key_id text NOT NULL,
    owner text NOT NULL,
    evidence jsonb NOT NULL,
    counter bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_attest_shadow_keys_counter_check CHECK (((counter >= 0) AND (counter <= '4294967295'::bigint)))
);


--
-- Name: autopilot_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.autopilot_events (
    command_id text NOT NULL,
    phase text NOT NULL,
    at timestamp with time zone NOT NULL,
    record jsonb NOT NULL
);


--
-- Name: balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.balances (
    account_id text NOT NULL,
    balance_micro_usd bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    withdrawable_micro_usd bigint DEFAULT 0 NOT NULL
);


--
-- Name: billing_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_sessions (
    id text NOT NULL,
    account_id text NOT NULL,
    payment_method text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    external_id text DEFAULT ''::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    referral_code text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone
);


--
-- Name: cache_routing_demand; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cache_routing_demand (
    key text NOT NULL,
    seen_at timestamp with time zone NOT NULL
);


--
-- Name: cache_routing_holders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cache_routing_holders (
    key text NOT NULL,
    cache_epoch text NOT NULL,
    tier text DEFAULT ''::text NOT NULL,
    model_id text NOT NULL,
    model_aggregate_hash text DEFAULT ''::text NOT NULL,
    prompt_contract_id text DEFAULT ''::text NOT NULL,
    block_hash_version text DEFAULT ''::text NOT NULL,
    ready_boundary_mode text DEFAULT ''::text NOT NULL,
    anchor_token_count integer DEFAULT 0 NOT NULL,
    required_recompute_tokens integer DEFAULT 0 NOT NULL,
    stage_ms double precision DEFAULT 0 NOT NULL,
    measured_stage_ms double precision DEFAULT 0 NOT NULL,
    measured_expires_at timestamp with time zone,
    updated_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: cache_routing_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cache_routing_meta (
    name text NOT NULL,
    value text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: code_attest_push_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.code_attest_push_budgets (
    se_pubkey text NOT NULL,
    token_hash text DEFAULT ''::text NOT NULL,
    next_push_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_clear_at timestamp with time zone
);


--
-- Name: code_attestations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.code_attestations (
    se_pubkey text NOT NULL,
    version text DEFAULT ''::text NOT NULL,
    attested_at timestamp with time zone DEFAULT now() NOT NULL,
    apns_token text DEFAULT ''::text NOT NULL,
    node_public_key text DEFAULT ''::text NOT NULL,
    binary_hash text DEFAULT ''::text NOT NULL,
    continuous_coverage_until timestamp with time zone
);


--
-- Name: darkbloom_machine_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.darkbloom_machine_aliases (
    kind text NOT NULL,
    scope text NOT NULL,
    digest text NOT NULL,
    machine_id text NOT NULL,
    verified_at timestamp with time zone NOT NULL
);


--
-- Name: darkbloom_machine_merges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.darkbloom_machine_merges (
    source_id text NOT NULL,
    target_id text NOT NULL,
    session_id text NOT NULL,
    merged_at timestamp with time zone NOT NULL,
    reason text NOT NULL
);


--
-- Name: darkbloom_machine_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.darkbloom_machine_observations (
    session_id text NOT NULL,
    observed_at timestamp with time zone NOT NULL,
    observation jsonb NOT NULL
);


--
-- Name: darkbloom_machine_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.darkbloom_machine_sessions (
    session_id text NOT NULL,
    machine_id text NOT NULL,
    original_machine_id text NOT NULL,
    account_id text NOT NULL,
    first_seen timestamp with time zone NOT NULL,
    last_seen timestamp with time zone NOT NULL,
    disconnected_at timestamp with time zone,
    observation jsonb NOT NULL
);


--
-- Name: darkbloom_machines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.darkbloom_machines (
    id text NOT NULL,
    assurance text NOT NULL,
    merged_into text,
    first_seen timestamp with time zone NOT NULL,
    last_seen timestamp with time zone NOT NULL
);


--
-- Name: device_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_codes (
    device_code text NOT NULL,
    user_code text NOT NULL,
    account_id text DEFAULT ''::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: earnings_summary; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.earnings_summary (
    key text NOT NULL,
    key_type text NOT NULL,
    total_count bigint DEFAULT 0 NOT NULL,
    total_micro_usd bigint DEFAULT 0 NOT NULL,
    total_prompt_tokens bigint DEFAULT 0 NOT NULL,
    total_completion_tokens bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: erasure_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.erasure_outbox (
    id text NOT NULL,
    request_id text NOT NULL,
    target text NOT NULL,
    external_id text DEFAULT ''::text NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_at timestamp with time zone DEFAULT now() NOT NULL,
    lease_until timestamp with time zone,
    last_error text DEFAULT ''::text NOT NULL,
    done_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT erasure_outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'done'::text, 'manual_action'::text]))),
    CONSTRAINT erasure_outbox_target_check CHECK ((target = ANY (ARRAY['stripe_account'::text, 'global_recipient'::text, 'checkout_sessions'::text, 'erasure_log'::text])))
);


--
-- Name: erasure_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.erasure_requests (
    id text NOT NULL,
    account_id text NOT NULL,
    actor text DEFAULT ''::text NOT NULL,
    canceled_by text DEFAULT ''::text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    state text NOT NULL,
    plan jsonb DEFAULT '{}'::jsonb NOT NULL,
    confirm_token_hash text DEFAULT ''::text NOT NULL,
    confirm_expires_at timestamp with time zone,
    wallet_addresses text[] DEFAULT '{}'::text[] NOT NULL,
    requested_at timestamp with time zone,
    scrub_after timestamp with time zone,
    erased_at timestamp with time zone,
    canceled_at timestamp with time zone,
    lease_until timestamp with time zone,
    last_error text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT erasure_requests_state_check CHECK ((state = ANY (ARRAY['planned'::text, 'pending'::text, 'erased'::text, 'canceled'::text])))
);


--
-- Name: fleet_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fleet_snapshots (
    id bigint NOT NULL,
    sampled_at timestamp with time zone NOT NULL,
    provider_id text NOT NULL,
    model text DEFAULT ''::text NOT NULL,
    eligibility_reason text DEFAULT ''::text NOT NULL,
    slot_state text DEFAULT ''::text NOT NULL,
    num_running integer DEFAULT 0 NOT NULL,
    num_waiting integer DEFAULT 0 NOT NULL,
    queued_prefill_tokens integer DEFAULT 0 NOT NULL,
    partial_prefill_rows integer DEFAULT 0 NOT NULL,
    active_token_budget_used bigint DEFAULT 0 NOT NULL,
    active_token_budget_max bigint DEFAULT 0 NOT NULL,
    kv_bytes_in_use bigint DEFAULT 0 NOT NULL,
    kv_bytes_capacity bigint DEFAULT 0 NOT NULL,
    observed_decode_tps double precision DEFAULT 0 NOT NULL,
    observed_prefill_tps double precision DEFAULT 0 NOT NULL,
    isolated_prefill_tps double precision DEFAULT 0 NOT NULL,
    ewma_initialized boolean,
    max_concurrency integer DEFAULT 0 NOT NULL,
    pending_count integer DEFAULT 0 NOT NULL,
    effective_cap integer DEFAULT 0 NOT NULL,
    cooldown_active boolean DEFAULT false NOT NULL,
    breaker_open boolean DEFAULT false NOT NULL,
    clamp_active boolean DEFAULT false NOT NULL,
    ejected boolean DEFAULT false NOT NULL,
    gpu_memory_active_gb double precision DEFAULT 0 NOT NULL,
    gpu_memory_peak_gb double precision DEFAULT 0 NOT NULL,
    free_for_load_gb double precision,
    memory_pressure double precision DEFAULT 0 NOT NULL,
    cpu_usage double precision DEFAULT 0 NOT NULL,
    thermal_state text DEFAULT ''::text NOT NULL,
    low_power_mode boolean,
    memory_pressure_level text DEFAULT ''::text NOT NULL,
    steps_executed bigint DEFAULT 0 NOT NULL,
    step_wall_ns_total bigint DEFAULT 0 NOT NULL,
    decode_rows_total bigint DEFAULT 0 NOT NULL,
    prefill_tokens_total bigint DEFAULT 0 NOT NULL,
    mtp_rounds_total bigint DEFAULT 0 NOT NULL,
    mtp_proposed_total bigint DEFAULT 0 NOT NULL,
    mtp_accepted_total bigint DEFAULT 0 NOT NULL,
    heartbeat_age_ms integer DEFAULT 0 NOT NULL,
    wedge_suspected boolean DEFAULT false NOT NULL,
    eval_in_flight_ms bigint DEFAULT 0 NOT NULL,
    requests_served bigint DEFAULT 0 NOT NULL,
    tokens_generated bigint DEFAULT 0 NOT NULL,
    cancellations_received bigint DEFAULT 0 NOT NULL,
    cancellations_before_output bigint DEFAULT 0 NOT NULL,
    cancellations_partial_complete bigint DEFAULT 0 NOT NULL,
    generation_errors_after_output bigint DEFAULT 0 NOT NULL,
    chunk_encryption_errors bigint DEFAULT 0 NOT NULL,
    stream_closed_without_terminal bigint DEFAULT 0 NOT NULL,
    cancel_during_model_load bigint DEFAULT 0 NOT NULL,
    usage_gaps bigint DEFAULT 0 NOT NULL,
    cancel_stage_pre_accept_total bigint DEFAULT 0 NOT NULL,
    cancel_stage_pre_engine_total bigint DEFAULT 0 NOT NULL,
    cancel_stage_prefill_total bigint DEFAULT 0 NOT NULL,
    cancel_stage_decode_total bigint DEFAULT 0 NOT NULL,
    cancel_stage_post_terminal_total bigint DEFAULT 0 NOT NULL,
    tokens_after_cancel_total bigint DEFAULT 0 NOT NULL,
    cancel_abort_ns_sum bigint DEFAULT 0 NOT NULL,
    queue_depth_total integer DEFAULT 0 NOT NULL,
    queue_depth_by_model jsonb,
    inflight_requests integer DEFAULT 0 NOT NULL,
    reserve_lock_wait_p95_us bigint DEFAULT 0 NOT NULL,
    profile_sink_depth integer DEFAULT 0 NOT NULL,
    profile_sink_dropped_total bigint DEFAULT 0 NOT NULL,
    route_sink_dropped_total bigint DEFAULT 0 NOT NULL,
    unknown_request_frames_total bigint DEFAULT 0 NOT NULL,
    goroutines integer DEFAULT 0 NOT NULL,
    provider_version text DEFAULT ''::text NOT NULL,
    model_vision boolean DEFAULT false NOT NULL,
    template_render_ok boolean
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.01');


--
-- Name: fleet_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.fleet_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fleet_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.fleet_snapshots_id_seq OWNED BY public.fleet_snapshots.id;


--
-- Name: global_payout_recipients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.global_payout_recipients (
    account_id text NOT NULL,
    country text NOT NULL,
    data jsonb NOT NULL
);


--
-- Name: global_payout_withdrawals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.global_payout_withdrawals (
    id text NOT NULL,
    account_id text NOT NULL,
    status text NOT NULL,
    external_id text DEFAULT ''::text NOT NULL,
    submitted_at timestamp with time zone NOT NULL,
    checked_at timestamp with time zone NOT NULL,
    lease_until timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    data jsonb NOT NULL
);


--
-- Name: inference_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inference_routes (
    id bigint NOT NULL,
    request_id text NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    provider_id text DEFAULT ''::text NOT NULL,
    model text NOT NULL,
    public_model text DEFAULT ''::text NOT NULL,
    consumer_key_hash text DEFAULT ''::text NOT NULL,
    key_id text DEFAULT ''::text NOT NULL,
    outcome text DEFAULT ''::text NOT NULL,
    cost_ms double precision,
    state_ms double precision,
    queue_ms double precision,
    pending_ms double precision,
    backlog_ms double precision,
    this_req_ms double precision,
    health_ms double precision,
    ttft_ms double precision,
    best_ttft_ms double precision,
    effective_queue integer,
    candidate_count integer,
    capacity_rejections integer,
    model_too_large_rejections integer,
    vision_rejections integer,
    ttft_rejections integer,
    effective_tps double precision,
    static_tps double precision,
    provider_status text,
    provider_trust_level text,
    provider_version text,
    hardware_chip text,
    hardware_chip_family text,
    hardware_tier text,
    memory_gb integer,
    gpu_cores integer,
    cpu_cores integer,
    system_memory_pressure double precision,
    system_cpu_usage double precision,
    system_thermal_state text,
    gpu_memory_active_gb double precision,
    gpu_memory_peak_gb double precision,
    gpu_memory_cache_gb double precision,
    slot_state text,
    backend_running integer,
    backend_waiting integer,
    active_token_budget_used bigint,
    active_token_budget_max bigint,
    queued_token_budget bigint,
    estimated_prompt_tokens integer,
    requested_max_tokens integer,
    requires_vision boolean DEFAULT false NOT NULL,
    has_tools boolean DEFAULT false NOT NULL,
    self_route_only boolean DEFAULT false NOT NULL,
    prefer_owner boolean DEFAULT false NOT NULL,
    cache_affinity_key text DEFAULT ''::text NOT NULL,
    final_status text DEFAULT ''::text NOT NULL,
    error_code integer,
    error_class text,
    prompt_tokens integer,
    completion_tokens integer,
    reasoning_tokens integer,
    cost_micro_usd bigint,
    actual_ttft_ms double precision,
    dispatch_to_first_chunk_ms double precision,
    total_duration_ms double precision,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    provider_region text,
    consumer_region text,
    parse_ms double precision,
    reserve_ms double precision,
    route_ms double precision,
    encrypt_ms double precision,
    queue_wait_ms double precision,
    dispatch_ms double precision,
    actual_decode_tps double precision,
    admitted_but_failed boolean,
    used_backup boolean,
    backup_won boolean,
    error_reason text
);


--
-- Name: inference_routes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inference_routes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inference_routes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inference_routes_id_seq OWNED BY public.inference_routes.id;


--
-- Name: invite_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invite_codes (
    code text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    max_uses integer DEFAULT 1 NOT NULL,
    used_count integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: invite_redemptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invite_redemptions (
    code text NOT NULL,
    account_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_entries (
    id bigint NOT NULL,
    account_id text NOT NULL,
    entry_type text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    balance_after bigint NOT NULL,
    reference text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ledger_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ledger_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ledger_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ledger_entries_id_seq OWNED BY public.ledger_entries.id;


--
-- Name: model_active_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_active_versions (
    model_id text NOT NULL,
    model_version_id bigint NOT NULL,
    activated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: model_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_aliases (
    alias_id text NOT NULL,
    display_name text DEFAULT ''::text NOT NULL,
    builds jsonb DEFAULT '[]'::jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    desired_build text DEFAULT ''::text NOT NULL,
    previous_build text DEFAULT ''::text NOT NULL,
    retired_builds jsonb DEFAULT '[]'::jsonb NOT NULL,
    openrouter_only boolean DEFAULT false NOT NULL,
    source_model text DEFAULT ''::text NOT NULL,
    source_kind text DEFAULT 'standard_alias'::text NOT NULL,
    openrouter_slug text DEFAULT ''::text NOT NULL,
    hugging_face_id text DEFAULT ''::text NOT NULL
);


--
-- Name: model_demand_collection; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_demand_collection (
    singleton boolean NOT NULL,
    started_at timestamp with time zone NOT NULL,
    CONSTRAINT model_demand_collection_singleton_check CHECK (singleton)
);


--
-- Name: model_demand_hourly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_demand_hourly (
    hour timestamp with time zone NOT NULL,
    model text NOT NULL,
    consumer_hash text NOT NULL,
    requests bigint NOT NULL,
    completed bigint NOT NULL,
    capacity_rejected bigint NOT NULL,
    latency_rejected bigint NOT NULL,
    timed_out bigint NOT NULL,
    failed bigint NOT NULL,
    cancelled bigint NOT NULL,
    unknown bigint NOT NULL,
    excluded bigint NOT NULL,
    http_429 bigint NOT NULL
);


--
-- Name: model_demand_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_demand_requests (
    id bigint NOT NULL,
    coord_request_id text NOT NULL,
    received_at timestamp with time zone NOT NULL,
    model text NOT NULL,
    consumer_hash text NOT NULL,
    outcome text NOT NULL,
    http_status integer NOT NULL,
    revision bigint NOT NULL,
    evidence_conflict boolean DEFAULT false NOT NULL
);


--
-- Name: model_demand_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_demand_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_demand_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_demand_requests_id_seq OWNED BY public.model_demand_requests.id;


--
-- Name: model_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_prices (
    account_id text NOT NULL,
    model text NOT NULL,
    input_price bigint NOT NULL,
    output_price bigint NOT NULL,
    cache_read_price bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: model_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_registry (
    id text NOT NULL,
    display_name text NOT NULL,
    family text DEFAULT ''::text NOT NULL,
    architecture text DEFAULT ''::text NOT NULL,
    quantization text DEFAULT ''::text NOT NULL,
    max_context_length integer DEFAULT 0 NOT NULL,
    max_output_length integer DEFAULT 0 NOT NULL,
    min_ram_gb integer DEFAULT 0 NOT NULL,
    capabilities text[] DEFAULT '{}'::text[] NOT NULL,
    required_provider_capabilities text[] DEFAULT '{}'::text[] NOT NULL,
    status text DEFAULT 'beta'::text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    runtime_parameters jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: model_token_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_token_grants (
    account_id text NOT NULL,
    model_id text NOT NULL,
    total_tokens bigint NOT NULL,
    used_tokens bigint DEFAULT 0 NOT NULL,
    reserved_tokens bigint DEFAULT 0 NOT NULL,
    claimed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT model_token_grants_check CHECK (((used_tokens + reserved_tokens) <= total_tokens)),
    CONSTRAINT model_token_grants_reserved_tokens_check CHECK ((reserved_tokens >= 0)),
    CONSTRAINT model_token_grants_total_tokens_check CHECK ((total_tokens > 0)),
    CONSTRAINT model_token_grants_used_tokens_check CHECK ((used_tokens >= 0))
);


--
-- Name: model_token_promotions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_token_promotions (
    model_id text NOT NULL,
    tokens bigint NOT NULL,
    claim_starts_at timestamp with time zone NOT NULL,
    claim_ends_at timestamp with time zone,
    signup_cutoff_at timestamp with time zone NOT NULL,
    max_claims bigint NOT NULL,
    claimed_count bigint DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    CONSTRAINT model_token_promotions_check CHECK ((claim_ends_at > claim_starts_at)),
    CONSTRAINT model_token_promotions_check1 CHECK (((claimed_count >= 0) AND (claimed_count <= max_claims))),
    CONSTRAINT model_token_promotions_max_claims_check CHECK (((max_claims > 0) AND (max_claims <= 1000000))),
    CONSTRAINT model_token_promotions_tokens_check CHECK (((tokens > 0) AND (tokens <= '1000000000000'::bigint)))
);


--
-- Name: model_token_provider_carries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_token_provider_carries (
    account_id text NOT NULL,
    remainder bigint DEFAULT 0 NOT NULL,
    CONSTRAINT model_token_provider_carries_remainder_check CHECK (((remainder >= 0) AND (remainder < 100000000)))
);


--
-- Name: model_token_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_token_reservations (
    id text NOT NULL,
    account_id text NOT NULL,
    model_id text NOT NULL,
    state text NOT NULL,
    record jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    touched_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT model_token_reservations_state_check CHECK ((state = ANY (ARRAY['reserved'::text, 'settled'::text, 'released'::text])))
);


--
-- Name: model_version_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_version_files (
    id bigint NOT NULL,
    model_version_id bigint NOT NULL,
    path text NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 text NOT NULL,
    role text NOT NULL
);


--
-- Name: model_version_files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_version_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_version_files_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_version_files_id_seq OWNED BY public.model_version_files.id;


--
-- Name: model_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_versions (
    id bigint NOT NULL,
    model_id text NOT NULL,
    version text NOT NULL,
    r2_prefix text NOT NULL,
    aggregate_sha256 text NOT NULL,
    total_size_bytes bigint NOT NULL,
    file_count integer NOT NULL,
    status text DEFAULT 'ready'::text NOT NULL,
    uploaded_by text DEFAULT ''::text NOT NULL,
    uploaded_at timestamp with time zone DEFAULT now() NOT NULL,
    promoted_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    hugging_face_artifact jsonb
);


--
-- Name: model_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_versions_id_seq OWNED BY public.model_versions.id;


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id bigint NOT NULL,
    tx_hash text,
    consumer_address text NOT NULL,
    provider_address text NOT NULL,
    amount_usd text NOT NULL,
    model text NOT NULL,
    prompt_tokens integer NOT NULL,
    completion_tokens integer NOT NULL,
    memo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payments_id_seq OWNED BY public.payments.id;


--
-- Name: provider_earnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_earnings (
    id bigint NOT NULL,
    account_id text NOT NULL,
    provider_id text NOT NULL,
    provider_key text DEFAULT ''::text NOT NULL,
    job_id text NOT NULL,
    model text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    prompt_tokens integer DEFAULT 0 NOT NULL,
    completion_tokens integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
)
WITH (autovacuum_analyze_scale_factor='0.005');


--
-- Name: provider_earnings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_earnings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_earnings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_earnings_id_seq OWNED BY public.provider_earnings.id;


--
-- Name: provider_floor_draws; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_floor_draws (
    id bigint NOT NULL,
    provider_key text NOT NULL,
    account_id text DEFAULT ''::text NOT NULL,
    epoch_id text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    floor_micro_usd bigint DEFAULT 0 NOT NULL,
    earned_micro_usd bigint DEFAULT 0 NOT NULL,
    uptime_frac double precision DEFAULT 0 NOT NULL,
    memory_gb integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: provider_floor_draws_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_floor_draws_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_floor_draws_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_floor_draws_id_seq OWNED BY public.provider_floor_draws.id;


--
-- Name: provider_log_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_log_reports (
    id bigint NOT NULL,
    serial_number text DEFAULT ''::text NOT NULL,
    provider_id text DEFAULT ''::text NOT NULL,
    account_id text DEFAULT ''::text NOT NULL,
    log_data bytea NOT NULL,
    log_size_bytes bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: provider_log_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_log_reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_log_reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_log_reports_id_seq OWNED BY public.provider_log_reports.id;


--
-- Name: provider_payouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_payouts (
    id bigint NOT NULL,
    provider_address text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    model text DEFAULT ''::text NOT NULL,
    job_id text DEFAULT ''::text NOT NULL,
    settled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: provider_payouts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_payouts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_payouts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_payouts_id_seq OWNED BY public.provider_payouts.id;


--
-- Name: provider_reputation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_reputation (
    provider_id text NOT NULL,
    total_jobs integer DEFAULT 0 NOT NULL,
    successful_jobs integer DEFAULT 0 NOT NULL,
    failed_jobs integer DEFAULT 0 NOT NULL,
    total_uptime_seconds bigint DEFAULT 0 NOT NULL,
    avg_response_time_ms bigint DEFAULT 0 NOT NULL,
    challenges_passed integer DEFAULT 0 NOT NULL,
    challenges_failed integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: provider_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_sessions (
    id bigint NOT NULL,
    session_id text NOT NULL,
    serial_number text DEFAULT ''::text NOT NULL,
    account_id text DEFAULT ''::text NOT NULL,
    connected_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen timestamp with time zone DEFAULT now() NOT NULL,
    disconnected_at timestamp with time zone,
    disconnect_reason text DEFAULT ''::text NOT NULL,
    provider_key text DEFAULT ''::text NOT NULL
);


--
-- Name: provider_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_sessions_id_seq OWNED BY public.provider_sessions.id;


--
-- Name: provider_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_tokens (
    token_hash text NOT NULL,
    account_id text NOT NULL,
    label text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: provider_trust_reuse; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_trust_reuse (
    se_pubkey text NOT NULL,
    serial text DEFAULT ''::text NOT NULL,
    trust_level text DEFAULT ''::text NOT NULL,
    binary_hash text DEFAULT ''::text NOT NULL,
    sip_enabled boolean DEFAULT false NOT NULL,
    secure_boot_full boolean DEFAULT false NOT NULL,
    mda_udid text DEFAULT ''::text NOT NULL,
    verified_at timestamp with time zone DEFAULT now() NOT NULL,
    last_verified_binary_hash text DEFAULT ''::text NOT NULL,
    hardware_proof_verified_at timestamp with time zone DEFAULT now() NOT NULL,
    application_proof_verified_at timestamp with time zone,
    evidence_generation bigint DEFAULT 1 NOT NULL,
    revocation_generation bigint DEFAULT 0 NOT NULL,
    revocation_event_id text DEFAULT ''::text NOT NULL,
    revoked_at timestamp with time zone,
    continuous_coverage_until timestamp with time zone
);


--
-- Name: provider_verification_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_verification_jobs (
    se_pubkey text NOT NULL,
    serial text DEFAULT ''::text NOT NULL,
    udid text DEFAULT ''::text NOT NULL,
    task_kind text NOT NULL,
    task_state text NOT NULL,
    priority smallint NOT NULL,
    retry_stage integer DEFAULT 0 NOT NULL,
    previous_delay_ns bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone,
    last_outcome text DEFAULT 'none'::text NOT NULL,
    reopen_pending boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    claim_owner text DEFAULT ''::text NOT NULL,
    claim_expires_at timestamp with time zone
);


--
-- Name: providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.providers (
    id text NOT NULL,
    hardware jsonb NOT NULL,
    models jsonb NOT NULL,
    backend text NOT NULL,
    location jsonb,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen timestamp with time zone DEFAULT now() NOT NULL,
    trust_level text DEFAULT 'none'::text NOT NULL,
    attested boolean DEFAULT false NOT NULL,
    attestation_result jsonb,
    se_public_key text DEFAULT ''::text NOT NULL,
    public_key text DEFAULT ''::text NOT NULL,
    serial_number text DEFAULT ''::text NOT NULL,
    mda_verified boolean DEFAULT false NOT NULL,
    mda_cert_chain jsonb,
    version text DEFAULT ''::text NOT NULL,
    runtime_verified boolean DEFAULT false NOT NULL,
    python_hash text DEFAULT ''::text NOT NULL,
    runtime_hash text DEFAULT ''::text NOT NULL,
    last_challenge_verified timestamp with time zone,
    failed_challenges integer DEFAULT 0 NOT NULL,
    account_id text DEFAULT ''::text NOT NULL,
    lifetime_requests_served bigint DEFAULT 0 NOT NULL,
    lifetime_tokens_generated bigint DEFAULT 0 NOT NULL,
    last_session_requests_served bigint DEFAULT 0 NOT NULL,
    last_session_tokens_generated bigint DEFAULT 0 NOT NULL,
    lifetime_stats jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_session_stats jsonb DEFAULT '{}'::jsonb NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: publishing_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.publishing_api_keys (
    id text NOT NULL,
    name text NOT NULL,
    key_hash text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone
);


--
-- Name: referrals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referrals (
    referred_account text NOT NULL,
    referrer_code text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: referrers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referrers (
    account_id text NOT NULL,
    code text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: releases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.releases (
    version text NOT NULL,
    platform text NOT NULL,
    backend text DEFAULT ''::text NOT NULL,
    binary_hash text DEFAULT ''::text NOT NULL,
    bundle_hash text DEFAULT ''::text NOT NULL,
    metallib_hash text DEFAULT ''::text NOT NULL,
    python_hash text DEFAULT ''::text NOT NULL,
    runtime_hash text DEFAULT ''::text NOT NULL,
    template_hashes text DEFAULT ''::text NOT NULL,
    grpc_binary_hash text DEFAULT ''::text NOT NULL,
    url text DEFAULT ''::text NOT NULL,
    changelog text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: request_outcomes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_outcomes (
    id bigint NOT NULL,
    coord_request_id text NOT NULL,
    received_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    revision bigint NOT NULL,
    evidence_conflict boolean DEFAULT false NOT NULL,
    record jsonb NOT NULL,
    CONSTRAINT request_outcomes_coord_request_id_check CHECK ((coord_request_id <> ''::text))
);


--
-- Name: request_outcomes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.request_outcomes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: request_outcomes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.request_outcomes_id_seq OWNED BY public.request_outcomes.id;


--
-- Name: request_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_profiles (
    id bigint NOT NULL,
    coord_request_id text NOT NULL,
    request_id text NOT NULL,
    attempt integer NOT NULL,
    backup_of text DEFAULT ''::text NOT NULL,
    winning boolean DEFAULT false NOT NULL,
    endpoint text DEFAULT ''::text NOT NULL,
    stream boolean DEFAULT false NOT NULL,
    model text DEFAULT ''::text NOT NULL,
    public_model text DEFAULT ''::text NOT NULL,
    provider_id text DEFAULT ''::text NOT NULL,
    provider_version text DEFAULT ''::text NOT NULL,
    chip_family text DEFAULT ''::text NOT NULL,
    kv_backend text DEFAULT ''::text NOT NULL,
    final_status text DEFAULT ''::text NOT NULL,
    error_reason text DEFAULT ''::text NOT NULL,
    terminal_cause text DEFAULT ''::text NOT NULL,
    client_outcome text DEFAULT ''::text NOT NULL,
    provider_outcome text DEFAULT ''::text NOT NULL,
    client_gone_phase text DEFAULT ''::text NOT NULL,
    first_content_budget_ms integer DEFAULT 0 NOT NULL,
    admission_mode text DEFAULT ''::text NOT NULL,
    predictive_bypass text DEFAULT ''::text NOT NULL,
    reservation_ttft_ceiling_ms double precision,
    dispatch_budget_ms bigint,
    estimated_prompt_tokens integer DEFAULT 0 NOT NULL,
    requested_max_tokens integer DEFAULT 0 NOT NULL,
    requires_vision boolean DEFAULT false NOT NULL,
    has_tools boolean DEFAULT false NOT NULL,
    received_at timestamp with time zone NOT NULL,
    auth_done_us bigint,
    ratelimit_done_us bigint,
    sealed_open_us bigint,
    handler_entry_us bigint,
    parsed_us bigint,
    reserved_us bigint,
    media_fetched_us bigint,
    preflight_done_us bigint,
    plan_done_us bigint,
    attempt_start_us bigint,
    reserve_lock_acquired_us bigint,
    reserve_done_us bigint,
    queued_us bigint,
    dequeued_us bigint,
    topup_done_us bigint,
    encrypted_us bigint,
    write_submitted_us bigint,
    write_dequeued_us bigint,
    write_done_us bigint,
    accepted_us bigint,
    first_chunk_ingress_us bigint,
    first_chunk_dequeued_us bigint,
    first_content_ingress_us bigint,
    first_content_us bigint,
    headers_written_us bigint,
    first_flush_us bigint,
    last_flush_us bigint,
    client_gone_us bigint,
    cancel_sent_us bigint,
    complete_ingress_us bigint,
    done_flushed_us bigint,
    finalized_us bigint,
    settle_db_us bigint,
    db_us bigint,
    db_calls integer DEFAULT 0 NOT NULL,
    body_bytes integer DEFAULT 0 NOT NULL,
    sealed_body_bytes integer DEFAULT 0 NOT NULL,
    auth_kind text DEFAULT ''::text NOT NULL,
    auth_db_read boolean DEFAULT false NOT NULL,
    reserve_mode text DEFAULT ''::text NOT NULL,
    media_items integer DEFAULT 0 NOT NULL,
    media_bytes bigint DEFAULT 0 NOT NULL,
    preflight_outcome text DEFAULT ''::text NOT NULL,
    plan_outcome text DEFAULT ''::text NOT NULL,
    chunks_in integer DEFAULT 0 NOT NULL,
    chunks_out integer DEFAULT 0 NOT NULL,
    bytes_out bigint DEFAULT 0 NOT NULL,
    decrypt_us_total bigint DEFAULT 0 NOT NULL,
    max_chunk_gap_us bigint DEFAULT 0 NOT NULL,
    held_preamble_chunks integer DEFAULT 0 NOT NULL,
    client_write_err boolean DEFAULT false NOT NULL,
    attempts_total integer DEFAULT 0 NOT NULL,
    failed_attempts integer DEFAULT 0 NOT NULL,
    failed_attempts_us bigint DEFAULT 0 NOT NULL,
    backup_launched boolean DEFAULT false NOT NULL,
    backup_won boolean DEFAULT false NOT NULL,
    transport_est_us bigint,
    slept_us bigint,
    timing_anomaly boolean DEFAULT false NOT NULL,
    candidate_set_size integer DEFAULT 0 NOT NULL,
    scanned integer DEFAULT 0 NOT NULL,
    gate_rejections jsonb,
    runner_up_provider_id text DEFAULT ''::text NOT NULL,
    runner_up_cost_ms double precision DEFAULT 0 NOT NULL,
    near_tie_pool_size integer DEFAULT 0 NOT NULL,
    selection_path text DEFAULT ''::text NOT NULL,
    best_idle_provider_id text DEFAULT ''::text NOT NULL,
    best_idle_ttft_ms double precision DEFAULT 0 NOT NULL,
    predicted_ttft_ms double precision DEFAULT 0 NOT NULL,
    raw_ttft_ms double precision DEFAULT 0 NOT NULL,
    predicted_decode_tps double precision DEFAULT 0 NOT NULL,
    snapshot_age_ms integer DEFAULT 0 NOT NULL,
    pending_for_model integer DEFAULT 0 NOT NULL,
    total_pending integer DEFAULT 0 NOT NULL,
    capacity_rate_ms double precision DEFAULT 0 NOT NULL,
    cache_discount_ms double precision DEFAULT 0 NOT NULL,
    shadow_would_shed boolean,
    shadow_idle_alternative boolean,
    lock_wait_us bigint DEFAULT 0 NOT NULL,
    scan_us bigint DEFAULT 0 NOT NULL,
    admit_us bigint DEFAULT 0 NOT NULL,
    preflight_us bigint DEFAULT 0 NOT NULL,
    ttft_calibration_ratio double precision DEFAULT 0 NOT NULL,
    prefill_decode_ratio double precision DEFAULT 0 NOT NULL,
    queue_position_at_enqueue integer DEFAULT 0 NOT NULL,
    queue_depth_at_enqueue integer DEFAULT 0 NOT NULL,
    drain_trigger text DEFAULT ''::text NOT NULL,
    candidates jsonb,
    prov_total_us bigint,
    prov_first_delta_us bigint,
    prov_engine_submit_us bigint,
    prov_engine_admitted_us bigint,
    prov_prompt_prep_us bigint,
    prov_load_wait_us bigint,
    prov_load_cold boolean,
    prov_running_at_admit integer,
    prov_waiting_at_admit integer,
    prov_kv_bytes_in_use_at_admit bigint,
    prov_cancel_stage text DEFAULT ''::text NOT NULL,
    eng_queue_wait_ns bigint,
    eng_first_token_ns bigint,
    eng_prompt_computed_ns bigint,
    eng_prefill_chunks integer,
    eng_decode_steps integer,
    eng_mtp_accepted integer,
    eng_finish_reason text DEFAULT ''::text NOT NULL,
    provider_profile jsonb,
    provider_profile_valid boolean DEFAULT false NOT NULL,
    provider_profile_invalid_reason text DEFAULT ''::text NOT NULL,
    provider_profile_consistent boolean,
    created_at timestamp with time zone DEFAULT now() NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.01');


--
-- Name: request_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.request_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: request_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.request_profiles_id_seq OWNED BY public.request_profiles.id;


--
-- Name: request_rejections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_rejections (
    id bigint NOT NULL,
    request_id text,
    endpoint text,
    stage text,
    reason_code text,
    http_status integer,
    consumer_key_hash text,
    key_id text,
    client_class text,
    requested_model text,
    resolved_model text,
    stream boolean,
    n integer,
    estimated_prompt_tokens integer,
    requested_max_tokens integer,
    requires_vision boolean,
    has_image boolean,
    has_audio boolean,
    has_tools boolean,
    tool_count integer,
    response_format text,
    self_route_only boolean,
    prefer_owner boolean,
    params jsonb,
    request_body_bytes integer,
    retry_after_ms integer,
    could_have_served boolean,
    candidate_count integer,
    capacity_rejections integer,
    model_too_large_rejections integer,
    vision_rejections integer,
    warm_provider_existed boolean,
    best_ttft_ms double precision,
    shortfall_micro_usd bigint,
    limit_kind text,
    over_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: request_rejections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.request_rejections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: request_rejections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.request_rejections_id_seq OWNED BY public.request_rejections.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    id text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: stripe_withdrawals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stripe_withdrawals (
    id text NOT NULL,
    account_id text NOT NULL,
    stripe_account_id text NOT NULL,
    transfer_id text DEFAULT ''::text NOT NULL,
    payout_id text DEFAULT ''::text NOT NULL,
    amount_micro_usd bigint NOT NULL,
    fee_micro_usd bigint DEFAULT 0 NOT NULL,
    net_micro_usd bigint NOT NULL,
    method text NOT NULL,
    status text NOT NULL,
    failure_reason text DEFAULT ''::text NOT NULL,
    refunded boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    fee_refunded boolean DEFAULT false NOT NULL,
    sweep_payout_id text DEFAULT ''::text NOT NULL
);


--
-- Name: usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage (
    id bigint NOT NULL,
    provider_id text NOT NULL,
    consumer_key_hash text NOT NULL,
    key_id text DEFAULT ''::text NOT NULL,
    model text NOT NULL,
    public_model text DEFAULT ''::text NOT NULL,
    prompt_tokens integer NOT NULL,
    cached_tokens integer DEFAULT 0 NOT NULL,
    completion_tokens integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    request_id text DEFAULT ''::text NOT NULL,
    cost_micro_usd bigint DEFAULT 0 NOT NULL,
    request_location jsonb
);


--
-- Name: usage_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.usage_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.usage_id_seq OWNED BY public.usage.id;


--
-- Name: usage_totals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_totals (
    id integer DEFAULT 1 NOT NULL,
    total_requests bigint DEFAULT 0 NOT NULL,
    total_prompt_tokens bigint DEFAULT 0 NOT NULL,
    total_completion_tokens bigint DEFAULT 0 NOT NULL,
    CONSTRAINT usage_totals_id_check CHECK ((id = 1))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    account_id text NOT NULL,
    privy_user_id text NOT NULL,
    email text DEFAULT ''::text NOT NULL,
    role text DEFAULT ''::text NOT NULL,
    platform_fee_percent bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    stripe_account_id text DEFAULT ''::text NOT NULL,
    stripe_account_status text DEFAULT ''::text NOT NULL,
    stripe_account_country text DEFAULT ''::text NOT NULL,
    stripe_destination_type text DEFAULT ''::text NOT NULL,
    stripe_destination_last4 text DEFAULT ''::text NOT NULL,
    stripe_instant_eligible boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: fleet_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fleet_snapshots ALTER COLUMN id SET DEFAULT nextval('public.fleet_snapshots_id_seq'::regclass);


--
-- Name: inference_routes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inference_routes ALTER COLUMN id SET DEFAULT nextval('public.inference_routes_id_seq'::regclass);


--
-- Name: ledger_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries ALTER COLUMN id SET DEFAULT nextval('public.ledger_entries_id_seq'::regclass);


--
-- Name: model_demand_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_demand_requests ALTER COLUMN id SET DEFAULT nextval('public.model_demand_requests_id_seq'::regclass);


--
-- Name: model_version_files id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_version_files ALTER COLUMN id SET DEFAULT nextval('public.model_version_files_id_seq'::regclass);


--
-- Name: model_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_versions ALTER COLUMN id SET DEFAULT nextval('public.model_versions_id_seq'::regclass);


--
-- Name: payments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments ALTER COLUMN id SET DEFAULT nextval('public.payments_id_seq'::regclass);


--
-- Name: provider_earnings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_earnings ALTER COLUMN id SET DEFAULT nextval('public.provider_earnings_id_seq'::regclass);


--
-- Name: provider_floor_draws id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_floor_draws ALTER COLUMN id SET DEFAULT nextval('public.provider_floor_draws_id_seq'::regclass);


--
-- Name: provider_log_reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_log_reports ALTER COLUMN id SET DEFAULT nextval('public.provider_log_reports_id_seq'::regclass);


--
-- Name: provider_payouts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_payouts ALTER COLUMN id SET DEFAULT nextval('public.provider_payouts_id_seq'::regclass);


--
-- Name: provider_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_sessions ALTER COLUMN id SET DEFAULT nextval('public.provider_sessions_id_seq'::regclass);


--
-- Name: request_outcomes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_outcomes ALTER COLUMN id SET DEFAULT nextval('public.request_outcomes_id_seq'::regclass);


--
-- Name: request_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_profiles ALTER COLUMN id SET DEFAULT nextval('public.request_profiles_id_seq'::regclass);


--
-- Name: request_rejections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_rejections ALTER COLUMN id SET DEFAULT nextval('public.request_rejections_id_seq'::regclass);


--
-- Name: usage id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage ALTER COLUMN id SET DEFAULT nextval('public.usage_id_seq'::regclass);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (key_hash);


--
-- Name: app_attest_build_qualifications app_attest_build_qualifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_build_qualifications
    ADD CONSTRAINT app_attest_build_qualifications_pkey PRIMARY KEY (binary_hash);


--
-- Name: app_attest_enrollments app_attest_enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_enrollments
    ADD CONSTRAINT app_attest_enrollments_pkey PRIMARY KEY (id);


--
-- Name: app_attest_evidence_blobs app_attest_evidence_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_evidence_blobs
    ADD CONSTRAINT app_attest_evidence_blobs_pkey PRIMARY KEY (evidence_id);


--
-- Name: app_attest_evidence app_attest_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_evidence
    ADD CONSTRAINT app_attest_evidence_pkey PRIMARY KEY (id);


--
-- Name: app_attest_key_revocations app_attest_key_revocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_key_revocations
    ADD CONSTRAINT app_attest_key_revocations_pkey PRIMARY KEY (key_id);


--
-- Name: app_attest_key_rotations app_attest_key_rotations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_key_rotations
    ADD CONSTRAINT app_attest_key_rotations_pkey PRIMARY KEY (key_id);


--
-- Name: app_attest_receipt_blobs app_attest_receipt_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_receipt_blobs
    ADD CONSTRAINT app_attest_receipt_blobs_pkey PRIMARY KEY (receipt_id);


--
-- Name: app_attest_receipt_jobs app_attest_receipt_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_receipt_jobs
    ADD CONSTRAINT app_attest_receipt_jobs_pkey PRIMARY KEY (key_id);


--
-- Name: app_attest_receipts app_attest_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_receipts
    ADD CONSTRAINT app_attest_receipts_pkey PRIMARY KEY (id);


--
-- Name: app_attest_shadow_events app_attest_shadow_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_shadow_events
    ADD CONSTRAINT app_attest_shadow_events_pkey PRIMARY KEY (id);


--
-- Name: app_attest_shadow_keys app_attest_shadow_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_shadow_keys
    ADD CONSTRAINT app_attest_shadow_keys_pkey PRIMARY KEY (key_id);


--
-- Name: autopilot_events autopilot_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.autopilot_events
    ADD CONSTRAINT autopilot_events_pkey PRIMARY KEY (command_id, phase);


--
-- Name: balances balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.balances
    ADD CONSTRAINT balances_pkey PRIMARY KEY (account_id);


--
-- Name: billing_sessions billing_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_sessions
    ADD CONSTRAINT billing_sessions_pkey PRIMARY KEY (id);


--
-- Name: cache_routing_demand cache_routing_demand_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_routing_demand
    ADD CONSTRAINT cache_routing_demand_pkey PRIMARY KEY (key);


--
-- Name: cache_routing_holders cache_routing_holders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_routing_holders
    ADD CONSTRAINT cache_routing_holders_pkey PRIMARY KEY (key, cache_epoch);


--
-- Name: cache_routing_meta cache_routing_meta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_routing_meta
    ADD CONSTRAINT cache_routing_meta_pkey PRIMARY KEY (name);


--
-- Name: code_attest_push_budgets code_attest_push_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.code_attest_push_budgets
    ADD CONSTRAINT code_attest_push_budgets_pkey PRIMARY KEY (se_pubkey, token_hash);


--
-- Name: code_attestations code_attestations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.code_attestations
    ADD CONSTRAINT code_attestations_pkey PRIMARY KEY (se_pubkey);


--
-- Name: darkbloom_machine_aliases darkbloom_machine_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_aliases
    ADD CONSTRAINT darkbloom_machine_aliases_pkey PRIMARY KEY (kind, scope, digest);


--
-- Name: darkbloom_machine_merges darkbloom_machine_merges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_merges
    ADD CONSTRAINT darkbloom_machine_merges_pkey PRIMARY KEY (source_id);


--
-- Name: darkbloom_machine_observations darkbloom_machine_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_observations
    ADD CONSTRAINT darkbloom_machine_observations_pkey PRIMARY KEY (session_id, observed_at);


--
-- Name: darkbloom_machine_sessions darkbloom_machine_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_sessions
    ADD CONSTRAINT darkbloom_machine_sessions_pkey PRIMARY KEY (session_id);


--
-- Name: darkbloom_machines darkbloom_machines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machines
    ADD CONSTRAINT darkbloom_machines_pkey PRIMARY KEY (id);


--
-- Name: device_codes device_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_codes
    ADD CONSTRAINT device_codes_pkey PRIMARY KEY (device_code);


--
-- Name: device_codes device_codes_user_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_codes
    ADD CONSTRAINT device_codes_user_code_key UNIQUE (user_code);


--
-- Name: earnings_summary earnings_summary_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.earnings_summary
    ADD CONSTRAINT earnings_summary_pkey PRIMARY KEY (key, key_type);


--
-- Name: erasure_outbox erasure_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_outbox
    ADD CONSTRAINT erasure_outbox_pkey PRIMARY KEY (id);


--
-- Name: erasure_requests erasure_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_requests
    ADD CONSTRAINT erasure_requests_pkey PRIMARY KEY (id);


--
-- Name: fleet_snapshots fleet_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fleet_snapshots
    ADD CONSTRAINT fleet_snapshots_pkey PRIMARY KEY (id);


--
-- Name: global_payout_recipients global_payout_recipients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.global_payout_recipients
    ADD CONSTRAINT global_payout_recipients_pkey PRIMARY KEY (account_id);


--
-- Name: global_payout_withdrawals global_payout_withdrawals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.global_payout_withdrawals
    ADD CONSTRAINT global_payout_withdrawals_pkey PRIMARY KEY (id);


--
-- Name: inference_routes inference_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inference_routes
    ADD CONSTRAINT inference_routes_pkey PRIMARY KEY (id);


--
-- Name: inference_routes inference_routes_request_id_attempt_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inference_routes
    ADD CONSTRAINT inference_routes_request_id_attempt_key UNIQUE (request_id, attempt);


--
-- Name: invite_codes invite_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_codes
    ADD CONSTRAINT invite_codes_pkey PRIMARY KEY (code);


--
-- Name: invite_redemptions invite_redemptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_redemptions
    ADD CONSTRAINT invite_redemptions_pkey PRIMARY KEY (code, account_id);


--
-- Name: ledger_entries ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (id);


--
-- Name: model_active_versions model_active_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_active_versions
    ADD CONSTRAINT model_active_versions_pkey PRIMARY KEY (model_id);


--
-- Name: model_aliases model_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_aliases
    ADD CONSTRAINT model_aliases_pkey PRIMARY KEY (alias_id);


--
-- Name: model_demand_collection model_demand_collection_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_demand_collection
    ADD CONSTRAINT model_demand_collection_pkey PRIMARY KEY (singleton);


--
-- Name: model_demand_hourly model_demand_hourly_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_demand_hourly
    ADD CONSTRAINT model_demand_hourly_pkey PRIMARY KEY (hour, model, consumer_hash);


--
-- Name: model_demand_requests model_demand_requests_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_demand_requests
    ADD CONSTRAINT model_demand_requests_id_key UNIQUE (id);


--
-- Name: model_demand_requests model_demand_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_demand_requests
    ADD CONSTRAINT model_demand_requests_pkey PRIMARY KEY (coord_request_id);


--
-- Name: model_prices model_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_prices
    ADD CONSTRAINT model_prices_pkey PRIMARY KEY (account_id, model);


--
-- Name: model_registry model_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_registry
    ADD CONSTRAINT model_registry_pkey PRIMARY KEY (id);


--
-- Name: model_token_grants model_token_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_grants
    ADD CONSTRAINT model_token_grants_pkey PRIMARY KEY (account_id, model_id);


--
-- Name: model_token_promotions model_token_promotions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_promotions
    ADD CONSTRAINT model_token_promotions_pkey PRIMARY KEY (model_id);


--
-- Name: model_token_provider_carries model_token_provider_carries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_provider_carries
    ADD CONSTRAINT model_token_provider_carries_pkey PRIMARY KEY (account_id);


--
-- Name: model_token_reservations model_token_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_reservations
    ADD CONSTRAINT model_token_reservations_pkey PRIMARY KEY (id);


--
-- Name: model_version_files model_version_files_model_version_id_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_version_files
    ADD CONSTRAINT model_version_files_model_version_id_path_key UNIQUE (model_version_id, path);


--
-- Name: model_version_files model_version_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_version_files
    ADD CONSTRAINT model_version_files_pkey PRIMARY KEY (id);


--
-- Name: model_versions model_versions_model_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_versions
    ADD CONSTRAINT model_versions_model_id_version_key UNIQUE (model_id, version);


--
-- Name: model_versions model_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_versions
    ADD CONSTRAINT model_versions_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: payments payments_tx_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_tx_hash_key UNIQUE (tx_hash);


--
-- Name: provider_earnings provider_earnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_earnings
    ADD CONSTRAINT provider_earnings_pkey PRIMARY KEY (id);


--
-- Name: provider_floor_draws provider_floor_draws_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_floor_draws
    ADD CONSTRAINT provider_floor_draws_pkey PRIMARY KEY (id);


--
-- Name: provider_floor_draws provider_floor_draws_provider_key_epoch_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_floor_draws
    ADD CONSTRAINT provider_floor_draws_provider_key_epoch_id_key UNIQUE (provider_key, epoch_id);


--
-- Name: provider_log_reports provider_log_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_log_reports
    ADD CONSTRAINT provider_log_reports_pkey PRIMARY KEY (id);


--
-- Name: provider_payouts provider_payouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_payouts
    ADD CONSTRAINT provider_payouts_pkey PRIMARY KEY (id);


--
-- Name: provider_reputation provider_reputation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_reputation
    ADD CONSTRAINT provider_reputation_pkey PRIMARY KEY (provider_id);


--
-- Name: provider_sessions provider_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_sessions
    ADD CONSTRAINT provider_sessions_pkey PRIMARY KEY (id);


--
-- Name: provider_sessions provider_sessions_session_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_sessions
    ADD CONSTRAINT provider_sessions_session_id_key UNIQUE (session_id);


--
-- Name: provider_tokens provider_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_tokens
    ADD CONSTRAINT provider_tokens_pkey PRIMARY KEY (token_hash);


--
-- Name: provider_trust_reuse provider_trust_reuse_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_trust_reuse
    ADD CONSTRAINT provider_trust_reuse_pkey PRIMARY KEY (se_pubkey);


--
-- Name: provider_verification_jobs provider_verification_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_verification_jobs
    ADD CONSTRAINT provider_verification_jobs_pkey PRIMARY KEY (se_pubkey, task_kind);


--
-- Name: providers providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_pkey PRIMARY KEY (id);


--
-- Name: publishing_api_keys publishing_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publishing_api_keys
    ADD CONSTRAINT publishing_api_keys_pkey PRIMARY KEY (id);


--
-- Name: referrals referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_pkey PRIMARY KEY (referred_account);


--
-- Name: referrers referrers_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrers
    ADD CONSTRAINT referrers_code_key UNIQUE (code);


--
-- Name: referrers referrers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrers
    ADD CONSTRAINT referrers_pkey PRIMARY KEY (account_id);


--
-- Name: releases releases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_pkey PRIMARY KEY (version, platform);


--
-- Name: request_outcomes request_outcomes_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_outcomes
    ADD CONSTRAINT request_outcomes_id_key UNIQUE (id);


--
-- Name: request_outcomes request_outcomes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_outcomes
    ADD CONSTRAINT request_outcomes_pkey PRIMARY KEY (coord_request_id);


--
-- Name: request_profiles request_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_profiles
    ADD CONSTRAINT request_profiles_pkey PRIMARY KEY (id);


--
-- Name: request_profiles request_profiles_request_id_attempt_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_profiles
    ADD CONSTRAINT request_profiles_request_id_attempt_key UNIQUE (request_id, attempt);


--
-- Name: request_rejections request_rejections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_rejections
    ADD CONSTRAINT request_rejections_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (id);


--
-- Name: stripe_withdrawals stripe_withdrawals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stripe_withdrawals
    ADD CONSTRAINT stripe_withdrawals_pkey PRIMARY KEY (id);


--
-- Name: usage usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage
    ADD CONSTRAINT usage_pkey PRIMARY KEY (id);


--
-- Name: usage_totals usage_totals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_totals
    ADD CONSTRAINT usage_totals_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (account_id);


--
-- Name: app_attest_evidence_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_evidence_key ON public.app_attest_evidence USING btree (key_id, received_at DESC);


--
-- Name: app_attest_evidence_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_evidence_pending ON public.app_attest_evidence USING btree (received_at) WHERE (outcome = 'pending'::text);


--
-- Name: app_attest_evidence_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_evidence_session ON public.app_attest_evidence USING btree (session_id, received_at DESC);


--
-- Name: app_attest_evidence_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_evidence_time ON public.app_attest_evidence USING btree (received_at DESC);


--
-- Name: app_attest_key_rotations_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_key_rotations_machine ON public.app_attest_key_rotations USING btree (machine_id, requested_at DESC);


--
-- Name: app_attest_receipts_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_receipts_key ON public.app_attest_receipts USING btree (key_id, received_at DESC);


--
-- Name: app_attest_receipts_recovery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_receipts_recovery ON public.app_attest_receipts USING btree (key_id, received_at DESC) WHERE (outcome = 'receipt_creation_time'::text);


--
-- Name: app_attest_shadow_events_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_shadow_events_session ON public.app_attest_shadow_events USING btree (session_id, observed_at DESC);


--
-- Name: app_attest_shadow_events_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_attest_shadow_events_time ON public.app_attest_shadow_events USING btree (observed_at DESC);


--
-- Name: autopilot_events_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX autopilot_events_at ON public.autopilot_events USING btree (at);


--
-- Name: darkbloom_machine_sessions_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX darkbloom_machine_sessions_machine ON public.darkbloom_machine_sessions USING btree (machine_id, last_seen DESC);


--
-- Name: darkbloom_machine_sessions_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX darkbloom_machine_sessions_open ON public.darkbloom_machine_sessions USING btree (last_seen, session_id) WHERE (disconnected_at IS NULL);


--
-- Name: darkbloom_machine_sessions_seen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX darkbloom_machine_sessions_seen ON public.darkbloom_machine_sessions USING btree (last_seen DESC);


--
-- Name: darkbloom_machines_merged_into; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX darkbloom_machines_merged_into ON public.darkbloom_machines USING btree (merged_into) WHERE (merged_into IS NOT NULL);


--
-- Name: erasure_outbox_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX erasure_outbox_due ON public.erasure_outbox USING btree (next_at) WHERE (state = 'pending'::text);


--
-- Name: erasure_outbox_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX erasure_outbox_request ON public.erasure_outbox USING btree (request_id);


--
-- Name: erasure_requests_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX erasure_requests_account ON public.erasure_requests USING btree (account_id, created_at DESC);


--
-- Name: erasure_requests_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX erasure_requests_due ON public.erasure_requests USING btree (scrub_after) WHERE (state = 'pending'::text);


--
-- Name: erasure_requests_open; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX erasure_requests_open ON public.erasure_requests USING btree (account_id) WHERE (state = ANY (ARRAY['planned'::text, 'pending'::text]));


--
-- Name: global_payout_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX global_payout_account ON public.global_payout_withdrawals USING btree (account_id, submitted_at DESC);


--
-- Name: global_payout_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX global_payout_external_id ON public.global_payout_withdrawals USING btree (external_id) WHERE (external_id <> ''::text);


--
-- Name: global_payout_quote_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX global_payout_quote_expiry ON public.global_payout_withdrawals USING btree (expires_at) WHERE (status = 'quoted'::text);


--
-- Name: global_payout_reconcile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX global_payout_reconcile ON public.global_payout_withdrawals USING btree (checked_at) WHERE (status = ANY (ARRAY['pending'::text, 'processing'::text, 'posted'::text]));


--
-- Name: idx_api_keys_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_api_keys_id ON public.api_keys USING btree (id) WHERE (id <> ''::text);


--
-- Name: idx_api_keys_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_keys_owner ON public.api_keys USING btree (owner_account_id) WHERE (owner_account_id <> ''::text);


--
-- Name: idx_billing_sessions_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_billing_sessions_account ON public.billing_sessions USING btree (account_id);


--
-- Name: idx_billing_sessions_external; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_billing_sessions_external ON public.billing_sessions USING btree (external_id);


--
-- Name: idx_billing_sessions_referral_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_billing_sessions_referral_code ON public.billing_sessions USING btree (referral_code) WHERE (referral_code <> ''::text);


--
-- Name: idx_cache_routing_demand_seen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_routing_demand_seen ON public.cache_routing_demand USING btree (seen_at);


--
-- Name: idx_cache_routing_holders_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_routing_holders_expires ON public.cache_routing_holders USING btree (expires_at);


--
-- Name: idx_cache_routing_holders_updated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cache_routing_holders_updated ON public.cache_routing_holders USING btree (updated_at);


--
-- Name: idx_code_attest_push_budgets_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_code_attest_push_budgets_due ON public.code_attest_push_budgets USING btree (next_push_at);


--
-- Name: idx_darkbloom_machine_sessions_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_darkbloom_machine_sessions_account ON public.darkbloom_machine_sessions USING btree (account_id);


--
-- Name: idx_device_codes_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_codes_account ON public.device_codes USING btree (account_id);


--
-- Name: idx_device_codes_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_codes_user ON public.device_codes USING btree (user_code);


--
-- Name: idx_fleet_snapshots_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fleet_snapshots_provider ON public.fleet_snapshots USING btree (provider_id, sampled_at DESC);


--
-- Name: idx_fleet_snapshots_sampled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fleet_snapshots_sampled ON public.fleet_snapshots USING btree (sampled_at DESC);


--
-- Name: idx_floor_draws_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_floor_draws_account ON public.provider_floor_draws USING btree (account_id, epoch_id);


--
-- Name: idx_floor_draws_epoch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_floor_draws_epoch ON public.provider_floor_draws USING btree (epoch_id);


--
-- Name: idx_inference_routes_consumer_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inference_routes_consumer_key_hash ON public.inference_routes USING btree (consumer_key_hash);


--
-- Name: idx_inference_routes_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inference_routes_created ON public.inference_routes USING btree (created_at DESC);


--
-- Name: idx_inference_routes_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inference_routes_model ON public.inference_routes USING btree (model, created_at DESC);


--
-- Name: idx_inference_routes_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inference_routes_provider ON public.inference_routes USING btree (provider_id, created_at DESC);


--
-- Name: idx_inference_routes_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inference_routes_request ON public.inference_routes USING btree (request_id);


--
-- Name: idx_ledger_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_account ON public.ledger_entries USING btree (account_id, created_at DESC);


--
-- Name: idx_ledger_reward; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_reward ON public.ledger_entries USING btree (account_id, created_at DESC) WHERE (entry_type = ANY (ARRAY['referral_reward'::text, 'admin_reward'::text]));


--
-- Name: idx_model_demand_received; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_model_demand_received ON public.model_demand_requests USING btree (received_at);


--
-- Name: idx_model_registry_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_model_registry_status ON public.model_registry USING btree (status);


--
-- Name: idx_model_token_reservations_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_model_token_reservations_account ON public.model_token_reservations USING btree (account_id);


--
-- Name: idx_model_token_reservations_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_model_token_reservations_open ON public.model_token_reservations USING btree (touched_at) WHERE (state = 'reserved'::text);


--
-- Name: idx_model_version_files_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_model_version_files_version ON public.model_version_files USING btree (model_version_id);


--
-- Name: idx_model_versions_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_model_versions_model ON public.model_versions USING btree (model_id);


--
-- Name: idx_provider_earnings_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_earnings_account ON public.provider_earnings USING btree (account_id, created_at DESC);


--
-- Name: idx_provider_earnings_created_at_brin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_earnings_created_at_brin ON public.provider_earnings USING brin (created_at) WITH (autosummarize='on');


--
-- Name: idx_provider_earnings_job; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_provider_earnings_job ON public.provider_earnings USING btree (job_id) WHERE (job_id <> ''::text);


--
-- Name: idx_provider_earnings_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_earnings_provider ON public.provider_earnings USING btree (provider_key, created_at DESC);


--
-- Name: idx_provider_log_reports_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_log_reports_account ON public.provider_log_reports USING btree (account_id);


--
-- Name: idx_provider_payouts_address; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_payouts_address ON public.provider_payouts USING btree (provider_address, created_at DESC);


--
-- Name: idx_provider_payouts_settled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_payouts_settled ON public.provider_payouts USING btree (settled, created_at DESC);


--
-- Name: idx_provider_sessions_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_sessions_account ON public.provider_sessions USING btree (account_id);


--
-- Name: idx_provider_sessions_connected; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_sessions_connected ON public.provider_sessions USING btree (connected_at DESC);


--
-- Name: idx_provider_sessions_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_sessions_key ON public.provider_sessions USING btree (provider_key, connected_at) WHERE (provider_key <> ''::text);


--
-- Name: idx_provider_sessions_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_sessions_open ON public.provider_sessions USING btree (connected_at) WHERE (disconnected_at IS NULL);


--
-- Name: idx_provider_sessions_serial; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_sessions_serial ON public.provider_sessions USING btree (serial_number, connected_at DESC);


--
-- Name: idx_provider_tokens_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_tokens_account ON public.provider_tokens USING btree (account_id);


--
-- Name: idx_provider_verification_jobs_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_verification_jobs_claim ON public.provider_verification_jobs USING btree (claim_expires_at) WHERE (claim_owner <> ''::text);


--
-- Name: idx_provider_verification_jobs_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_verification_jobs_due ON public.provider_verification_jobs USING btree (priority, next_attempt_at) WHERE (task_state = ANY (ARRAY['pending'::text, 'backoff'::text]));


--
-- Name: idx_providers_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_providers_account ON public.providers USING btree (account_id, last_seen DESC) WHERE (account_id <> ''::text);


--
-- Name: idx_providers_restore_se_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_providers_restore_se_key ON public.providers USING btree (se_public_key, last_seen DESC, id DESC) WHERE (se_public_key <> ''::text);


--
-- Name: idx_providers_restore_serial; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_providers_restore_serial ON public.providers USING btree (serial_number, last_seen DESC, id DESC) WHERE (serial_number <> ''::text);


--
-- Name: idx_providers_serial; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_providers_serial ON public.providers USING btree (serial_number) WHERE (serial_number <> ''::text);


--
-- Name: idx_publishing_api_keys_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_publishing_api_keys_hash ON public.publishing_api_keys USING btree (key_hash);


--
-- Name: idx_referrals_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_referrals_code ON public.referrals USING btree (referrer_code);


--
-- Name: idx_referrers_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_referrers_code ON public.referrers USING btree (code);


--
-- Name: idx_request_outcomes_received; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_outcomes_received ON public.request_outcomes USING btree (received_at, coord_request_id);


--
-- Name: idx_request_profiles_coord; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_profiles_coord ON public.request_profiles USING btree (coord_request_id);


--
-- Name: idx_request_profiles_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_profiles_created ON public.request_profiles USING btree (created_at DESC);


--
-- Name: idx_request_profiles_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_profiles_provider ON public.request_profiles USING btree (provider_id, created_at DESC);


--
-- Name: idx_request_rejections_consumer_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_rejections_consumer_key_hash ON public.request_rejections USING btree (consumer_key_hash);


--
-- Name: idx_request_rejections_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_rejections_created ON public.request_rejections USING btree (created_at DESC);


--
-- Name: idx_request_rejections_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_rejections_model ON public.request_rejections USING btree (resolved_model, created_at DESC);


--
-- Name: idx_request_rejections_reason; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_rejections_reason ON public.request_rejections USING btree (reason_code, created_at DESC);


--
-- Name: idx_request_rejections_servable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_rejections_servable ON public.request_rejections USING btree (could_have_served, created_at DESC) WHERE (could_have_served = true);


--
-- Name: idx_request_rejections_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_request_rejections_status ON public.request_rejections USING btree (http_status, created_at DESC);


--
-- Name: idx_stripe_withdrawals_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stripe_withdrawals_account ON public.stripe_withdrawals USING btree (account_id, created_at DESC);


--
-- Name: idx_stripe_withdrawals_payout; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_stripe_withdrawals_payout ON public.stripe_withdrawals USING btree (payout_id) WHERE (payout_id <> ''::text);


--
-- Name: idx_stripe_withdrawals_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stripe_withdrawals_status ON public.stripe_withdrawals USING btree (status, created_at);


--
-- Name: idx_stripe_withdrawals_stripe_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stripe_withdrawals_stripe_account ON public.stripe_withdrawals USING btree (stripe_account_id, status);


--
-- Name: idx_stripe_withdrawals_sweep_payout; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stripe_withdrawals_sweep_payout ON public.stripe_withdrawals USING btree (sweep_payout_id) WHERE (sweep_payout_id <> ''::text);


--
-- Name: idx_stripe_withdrawals_transfer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_stripe_withdrawals_transfer ON public.stripe_withdrawals USING btree (transfer_id) WHERE (transfer_id <> ''::text);


--
-- Name: idx_usage_consumer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_consumer ON public.usage USING btree (consumer_key_hash, created_at DESC);


--
-- Name: idx_usage_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_created ON public.usage USING btree (created_at DESC);


--
-- Name: idx_usage_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_key ON public.usage USING btree (key_id, created_at DESC) WHERE (key_id <> ''::text);


--
-- Name: idx_usage_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_provider ON public.usage USING btree (provider_id, created_at DESC);


--
-- Name: idx_usage_request_location_notnull; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_request_location_notnull ON public.usage USING btree (created_at DESC) WHERE (request_location IS NOT NULL);


--
-- Name: idx_users_privy_deleted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_privy_deleted ON public.users USING btree (privy_user_id) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_users_privy_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_privy_live ON public.users USING btree (privy_user_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_users_stripe_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_stripe_account ON public.users USING btree (stripe_account_id) WHERE (stripe_account_id <> ''::text);


--
-- Name: inference_routes clear_legacy_cache_affinity_key; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER clear_legacy_cache_affinity_key BEFORE INSERT OR UPDATE OF cache_affinity_key ON public.inference_routes FOR EACH ROW EXECUTE FUNCTION public.clear_legacy_cache_affinity_key();


--
-- Name: provider_log_reports clear_provider_log_report_serial; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER clear_provider_log_report_serial BEFORE INSERT OR UPDATE OF serial_number ON public.provider_log_reports FOR EACH ROW EXECUTE FUNCTION public.clear_provider_log_report_serial();


--
-- Name: model_demand_requests model_demand_rollup; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER model_demand_rollup AFTER INSERT OR UPDATE ON public.model_demand_requests FOR EACH ROW EXECUTE FUNCTION public.update_model_demand_hourly();


--
-- Name: app_attest_evidence_blobs app_attest_evidence_blobs_evidence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_evidence_blobs
    ADD CONSTRAINT app_attest_evidence_blobs_evidence_id_fkey FOREIGN KEY (evidence_id) REFERENCES public.app_attest_evidence(id);


--
-- Name: app_attest_key_revocations app_attest_key_revocations_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_key_revocations
    ADD CONSTRAINT app_attest_key_revocations_key_id_fkey FOREIGN KEY (key_id) REFERENCES public.app_attest_shadow_keys(key_id);


--
-- Name: app_attest_receipt_blobs app_attest_receipt_blobs_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_receipt_blobs
    ADD CONSTRAINT app_attest_receipt_blobs_receipt_id_fkey FOREIGN KEY (receipt_id) REFERENCES public.app_attest_receipts(id);


--
-- Name: app_attest_receipt_jobs app_attest_receipt_jobs_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_attest_receipt_jobs
    ADD CONSTRAINT app_attest_receipt_jobs_receipt_id_fkey FOREIGN KEY (receipt_id) REFERENCES public.app_attest_receipts(id);


--
-- Name: darkbloom_machine_aliases darkbloom_machine_aliases_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_aliases
    ADD CONSTRAINT darkbloom_machine_aliases_machine_id_fkey FOREIGN KEY (machine_id) REFERENCES public.darkbloom_machines(id);


--
-- Name: darkbloom_machine_merges darkbloom_machine_merges_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_merges
    ADD CONSTRAINT darkbloom_machine_merges_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.darkbloom_machines(id);


--
-- Name: darkbloom_machine_merges darkbloom_machine_merges_target_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_merges
    ADD CONSTRAINT darkbloom_machine_merges_target_id_fkey FOREIGN KEY (target_id) REFERENCES public.darkbloom_machines(id);


--
-- Name: darkbloom_machine_sessions darkbloom_machine_sessions_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_sessions
    ADD CONSTRAINT darkbloom_machine_sessions_machine_id_fkey FOREIGN KEY (machine_id) REFERENCES public.darkbloom_machines(id);


--
-- Name: darkbloom_machine_sessions darkbloom_machine_sessions_original_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machine_sessions
    ADD CONSTRAINT darkbloom_machine_sessions_original_machine_id_fkey FOREIGN KEY (original_machine_id) REFERENCES public.darkbloom_machines(id);


--
-- Name: darkbloom_machines darkbloom_machines_merged_into_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.darkbloom_machines
    ADD CONSTRAINT darkbloom_machines_merged_into_fkey FOREIGN KEY (merged_into) REFERENCES public.darkbloom_machines(id);


--
-- Name: erasure_outbox erasure_outbox_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_outbox
    ADD CONSTRAINT erasure_outbox_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.erasure_requests(id);


--
-- Name: invite_redemptions invite_redemptions_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invite_redemptions
    ADD CONSTRAINT invite_redemptions_code_fkey FOREIGN KEY (code) REFERENCES public.invite_codes(code);


--
-- Name: model_active_versions model_active_versions_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_active_versions
    ADD CONSTRAINT model_active_versions_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.model_registry(id) ON DELETE CASCADE;


--
-- Name: model_active_versions model_active_versions_model_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_active_versions
    ADD CONSTRAINT model_active_versions_model_version_id_fkey FOREIGN KEY (model_version_id) REFERENCES public.model_versions(id) ON DELETE RESTRICT;


--
-- Name: model_token_grants model_token_grants_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_grants
    ADD CONSTRAINT model_token_grants_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.users(account_id);


--
-- Name: model_token_grants model_token_grants_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_grants
    ADD CONSTRAINT model_token_grants_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.model_token_promotions(model_id);


--
-- Name: model_token_reservations model_token_reservations_account_id_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_token_reservations
    ADD CONSTRAINT model_token_reservations_account_id_model_id_fkey FOREIGN KEY (account_id, model_id) REFERENCES public.model_token_grants(account_id, model_id);


--
-- Name: model_version_files model_version_files_model_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_version_files
    ADD CONSTRAINT model_version_files_model_version_id_fkey FOREIGN KEY (model_version_id) REFERENCES public.model_versions(id) ON DELETE CASCADE;


--
-- Name: model_versions model_versions_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_versions
    ADD CONSTRAINT model_versions_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.model_registry(id) ON DELETE CASCADE;


--
-- Name: provider_reputation provider_reputation_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_reputation
    ADD CONSTRAINT provider_reputation_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id);


--
-- Name: referrals referrals_referrer_code_cascade_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_referrer_code_cascade_fkey FOREIGN KEY (referrer_code) REFERENCES public.referrers(code) ON UPDATE CASCADE;


--
-- PostgreSQL database dump complete
--


