-- Read-only aggregate query. Required psql variables and metric definitions:
-- README.md. Run in a repeatable-read, read-only transaction on a replica.
-- IDs remain inside this query; no customer, provider, request, or content rows
-- are returned. The comparison is descriptive, not a causal release estimate.
WITH RECURSIVE
windows(cohort, since, until, sample_rate) AS (
  VALUES
    ('before', :'before_start'::timestamptz, :'before_end'::timestamptz,
     :'before_sample_rate'::double precision),
    ('after', :'after_start'::timestamptz, :'after_end'::timestamptz,
     :'after_sample_rate'::double precision)
),
config AS (
  SELECT bool_and(since < until AND until - since <= interval '24 hours'
                  AND sample_rate > 0 AND sample_rate <= 1)
         AND (SELECT b.until <= a.since FROM windows b CROSS JOIN windows a
              WHERE b.cohort = 'before' AND a.cohort = 'after') AS valid,
         min(sample_rate) AS common_sample_rate
  FROM windows
),
cohort AS MATERIALIZED (
  SELECT w.cohort, o.coord_request_id, o.record,
         o.evidence_conflict OR coalesce((o.record->>'evidence_conflict')::boolean, false) AS conflict,
         (o.record->>'http_status')::int AS http_status,
         coalesce((o.record->>'attempts_total')::int, 0) AS attempts_total,
         (o.record->>'attempts_complete')::boolean
           AND NOT coalesce((o.record->>'attempts_truncated')::boolean, false) AS attempts_complete,
         o.record->>'endpoint' AS endpoint, o.record->>'stream' AS stream,
         o.record->>'termination' = 'completed'
           AND (o.record->>'http_status')::int BETWEEN 200 AND 299 AS completed
  FROM request_outcomes o JOIN windows w
    ON o.received_at >= w.since AND o.received_at < w.until
  CROSS JOIN config
  WHERE config.valid AND o.record->>'model' = :'model'
),
attempt_counts AS (
  SELECT c.*,
    (SELECT count(*) FROM jsonb_array_elements(coalesce(record->'attempts', '[]'::jsonb)) a
     WHERE a->>'raw_reason' = 'first_chunk_timeout' AND a->>'final_status' = 'timeout') AS timeout_attempts,
    (SELECT count(*) FROM jsonb_array_elements(coalesce(record->'attempts', '[]'::jsonb)) a
     WHERE coalesce(a->>'backup_of', '') <> '') AS hedge_attempts
  FROM cohort c
),
outcomes AS (
  SELECT cohort, endpoint, stream, count(*) AS logical_requests,
    count(*) FILTER (WHERE http_status = 429) AS http_429_requests,
    count(*) FILTER (WHERE http_status = 0) AS status_zero_requests,
    count(*) FILTER (WHERE completed AND NOT conflict) AS completed_requests,
    count(*) FILTER (WHERE conflict) AS evidence_conflict_requests,
    count(*) FILTER (WHERE NOT attempts_complete OR attempts_complete IS NULL) AS incomplete_attempt_records,
    count(*) FILTER (WHERE record->>'handler_finished_at' IS NULL) AS unfinished_handlers,
    count(*) FILTER (WHERE NOT conflict AND record->>'normalized_code' = 'ext_first_content_timeout') AS final_actual_first_content_timeouts,
    count(*) FILTER (WHERE NOT conflict AND record->>'termination' = 'rejected'
      AND record->>'raw_reason' = 'deadline_unreachable') AS predictive_deadline_rejections,
    count(*) FILTER (WHERE NOT conflict AND timeout_attempts > 0) AS requests_with_recorded_timeout_attempt,
    sum(timeout_attempts) FILTER (WHERE NOT conflict) AS recorded_timeout_attempts,
    count(*) FILTER (WHERE attempts_complete AND NOT conflict) AS retry_denominator_requests,
    sum(greatest(attempts_total - 1, 0)) FILTER (WHERE attempts_complete AND NOT conflict) AS additional_attempts,
    sum(hedge_attempts) FILTER (WHERE attempts_complete AND NOT conflict) AS hedge_attempts,
    avg(greatest(attempts_total - 1, 0)::numeric) FILTER (WHERE attempts_complete AND NOT conflict) AS additional_attempts_per_request,
    avg(greatest(attempts_total - 1 - hedge_attempts, 0)::numeric) FILTER (WHERE attempts_complete AND NOT conflict) AS additional_non_hedge_attempts_per_request,
    count(*) FILTER (WHERE attempts_complete AND NOT conflict AND attempts_total > 1) AS requests_with_additional_attempts
  FROM attempt_counts GROUP BY cohort, endpoint, stream
),
-- profiler.sampled: FNV-1a 32-bit of the UTF-8 logical coordinator ID, then
-- float64(hash) / 2^32 < configured rate. A common smaller rate is a subset of
-- each period's original sample, even when the configured rates differ.
hashes(cohort, coord_request_id, bytes, position, hash) AS (
  SELECT cohort, coord_request_id, convert_to(coord_request_id, 'UTF8'), 0, 2166136261::bigint
  FROM cohort
  UNION ALL
  SELECT cohort, coord_request_id, bytes, position + 1,
         ((hash # get_byte(bytes, position)::bigint) * 16777619) & 4294967295::bigint
  FROM hashes WHERE position < octet_length(bytes)
),
sampled AS MATERIALIZED (
  SELECT c.* FROM cohort c JOIN hashes h USING (cohort, coord_request_id)
  CROSS JOIN config
  WHERE h.position = octet_length(h.bytes)
    AND (c.coord_request_id = '' OR h.hash::double precision / 4294967296.0 < config.common_sample_rate)
),
-- Fail closed on ambiguous multiple successful winners. Earlier failed and
-- speculative losing attempts never become additional latency observations.
winning AS (
  SELECT s.cohort, s.coord_request_id, count(*) AS winner_count,
         min(p.first_content_us) AS first_content_us,
         min(p.first_content_budget_ms) AS first_content_budget_ms,
         min(CASE WHEN p.provider_profile_valid AND p.provider_profile_consistent IS TRUE
                  THEN (p.provider_profile->>'prompt_tokens')::int END) AS actual_prompt_tokens,
         min(p.provider_version) AS provider_version,
         min(p.chip_family) AS chip_family, min(p.kv_backend) AS kv_backend,
         min(p.provider_profile->>'mtp_active') AS mtp_active,
         bool_or(p.has_tools) AS has_tools, bool_or(p.requires_vision) AS requires_vision,
         min(p.requested_max_tokens) AS requested_max_tokens,
         bool_or(p.timing_anomaly) AS timing_anomaly
  FROM sampled s JOIN request_profiles p ON p.coord_request_id = s.coord_request_id
  WHERE s.completed AND NOT s.conflict AND p.winning AND p.final_status = 'success'
  GROUP BY s.cohort, s.coord_request_id
),
sample_coverage AS (
  SELECT s.cohort, s.endpoint, s.stream,
    count(*) AS sampled_logical_requests,
    count(*) FILTER (WHERE s.completed AND NOT s.conflict) AS sampled_completed_requests,
    count(*) FILTER (WHERE w.winner_count = 1 AND w.first_content_us > 0 AND NOT w.timing_anomaly) AS timed_completed_requests,
    count(*) FILTER (WHERE w.winner_count = 1 AND w.first_content_us > 0 AND NOT w.timing_anomaly
      AND w.first_content_budget_ms > 0) AS timed_completed_requests_with_budget,
    count(*) FILTER (WHERE w.winner_count = 1 AND w.first_content_us > 0 AND NOT w.timing_anomaly
      AND w.first_content_budget_ms > 0
      AND w.first_content_us <= w.first_content_budget_ms::bigint * 1000) AS coordinator_on_time_completed_requests,
    count(*) FILTER (WHERE w.winner_count = 1 AND w.first_content_us > 0 AND NOT w.timing_anomaly
      AND w.actual_prompt_tokens > 0) AS prompt_banded_completed_requests,
    count(*) FILTER (WHERE w.winner_count > 1) AS ambiguous_winner_requests
  FROM sampled s LEFT JOIN winning w USING (cohort, coord_request_id)
  GROUP BY s.cohort, s.endpoint, s.stream
),
banded AS (
  SELECT s.cohort, w.provider_version, w.first_content_us / 1000.0 AS first_content_ms,
    jsonb_build_object(
      'endpoint', s.endpoint, 'stream', s.stream, 'has_tools', w.has_tools,
      'requires_vision', w.requires_vision, 'chip_family', w.chip_family,
      'kv_backend', w.kv_backend, 'mtp_active', w.mtp_active,
      'first_content_budget_ms', w.first_content_budget_ms,
      'requested_output_band', CASE WHEN w.requested_max_tokens <= 0 THEN 'unknown'
        WHEN w.requested_max_tokens <= 256 THEN '1-256'
        WHEN w.requested_max_tokens <= 2048 THEN '257-2048' ELSE '2049+' END,
      'actual_prompt_band', CASE WHEN w.actual_prompt_tokens < 4096 THEN '1-4095'
        WHEN w.actual_prompt_tokens < 16384 THEN '4096-16383'
        WHEN w.actual_prompt_tokens < 32768 THEN '16384-32767' ELSE '32768+' END
    ) AS stratum
  FROM sampled s JOIN winning w USING (cohort, coord_request_id)
  WHERE w.winner_count = 1 AND w.first_content_us > 0 AND NOT w.timing_anomaly
    AND w.actual_prompt_tokens > 0
),
latency AS (
  SELECT cohort, stratum, count(*) AS successful_requests,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY first_content_ms) AS first_content_p50_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY first_content_ms) AS first_content_p95_ms,
    array_agg(DISTINCT provider_version ORDER BY provider_version) AS provider_versions
  FROM banded GROUP BY cohort, stratum
),
matched_latency AS (
  SELECT l.*, EXISTS (SELECT 1 FROM latency other
    WHERE other.cohort <> l.cohort AND other.stratum = l.stratum) AS matched_in_both_periods
  FROM latency l
),
provider_release_mix AS (
  SELECT cohort, provider_version, count(*) AS prompt_banded_completed_requests
  FROM banded GROUP BY cohort, provider_version
)
SELECT jsonb_build_object(
  'schema_version', 1, 'parameters_valid', config.valid, 'model', :'model',
  'extracted_at', transaction_timestamp(), 'replica_replay_at', pg_last_xact_replay_timestamp(),
  'common_profile_sample_rate', config.common_sample_rate,
  'windows', (SELECT jsonb_agg(to_jsonb(w) ORDER BY cohort) FROM windows w),
  'logical_outcomes', coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY cohort, endpoint, stream) FROM outcomes o), '[]'::jsonb),
  'profile_sample_coverage', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY cohort, endpoint, stream) FROM sample_coverage s), '[]'::jsonb),
  'successful_first_content', coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY stratum::text, cohort) FROM matched_latency l), '[]'::jsonb),
  'provider_release_mix', coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY cohort, provider_version) FROM provider_release_mix v), '[]'::jsonb),
  'provider_decode_token_gaps', jsonb_build_object('status', 'not_recorded_in_production_profiles'),
  'upstream_receipt', 'not_observed', 'causal_release_effect', 'not_identified'
) FROM config;
