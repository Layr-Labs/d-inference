export const SUPPLY_PRESSURE_SQL = `
  WITH rejection_events AS (
    SELECT COALESCE(
             NULLIF(resolved_model, ''),
             NULLIF(requested_model, ''),
             '(unknown)'
           ) AS model,
           reason_code,
           best_ttft_ms,
           created_at
      FROM request_rejections
     WHERE created_at >= now() - interval '24 hours'
       AND COALESCE(self_route_only, false) = false
       AND reason_code = ANY($4::text[])
  ),
  rejection_rollup AS (
    SELECT model,
           count(*) FILTER (
             WHERE reason_code = ANY($3::text[])
               AND created_at >= now() - interval '1 hour'
           )::bigint AS supply_rejects_1h,
           count(*) FILTER (
             WHERE reason_code = ANY($3::text[])
           )::bigint AS supply_rejects_24h,
           count(*) FILTER (
             WHERE reason_code = ANY($1::text[])
               AND created_at >= now() - interval '1 hour'
           )::bigint AS capacity_sheds_1h,
           count(*) FILTER (
             WHERE reason_code = ANY($1::text[])
           )::bigint AS capacity_sheds_24h,
           count(*) FILTER (
             WHERE reason_code = ANY($2::text[])
               AND created_at >= now() - interval '1 hour'
           )::bigint AS latency_sheds_1h,
           count(*) FILTER (
             WHERE reason_code = ANY($2::text[])
           )::bigint AS latency_sheds_24h,
           count(*) FILTER (
             WHERE reason_code = 'no_provider'
               AND created_at >= now() - interval '1 hour'
           )::bigint AS unavailable_sheds_1h,
           count(*) FILTER (
             WHERE reason_code = 'no_provider'
           )::bigint AS unavailable_sheds_24h,
           count(*) FILTER (
             WHERE reason_code = 'model_too_large'
               AND created_at >= now() - interval '1 hour'
           )::bigint AS hardware_mismatches_1h,
           count(*) FILTER (
             WHERE reason_code = 'model_too_large'
           )::bigint AS hardware_mismatches_24h,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY best_ttft_ms) FILTER (
             WHERE reason_code = ANY($2::text[])
               AND best_ttft_ms > 0
               AND created_at >= now() - interval '1 hour'
           ) AS rejected_ttft_p95_ms_1h,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY best_ttft_ms) FILTER (
             WHERE reason_code = ANY($2::text[])
               AND best_ttft_ms > 0
           ) AS rejected_ttft_p95_ms_24h
      FROM rejection_events
     GROUP BY model
  ),
  route_rollup AS (
    SELECT model,
           count(*)::bigint AS served_24h,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY actual_ttft_ms) FILTER (
             WHERE created_at >= now() - interval '1 hour'
               AND actual_ttft_ms > 0
           ) AS actual_ttft_p95_ms_1h,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY actual_ttft_ms) FILTER (
             WHERE actual_ttft_ms > 0
           ) AS actual_ttft_p95_ms_24h
      FROM inference_routes
     WHERE created_at >= now() - interval '24 hours'
       AND model <> ''
       AND COALESCE(self_route_only, false) = false
       AND final_status IN ('success', 'partial_success')
     GROUP BY model
  ),
  model_keys AS (
    SELECT model FROM rejection_rollup
    UNION
    SELECT model FROM route_rollup
  )
  SELECT mk.model,
         mr.display_name,
         mr.min_ram_gb,
         COALESCE(rr.supply_rejects_1h, 0)::bigint AS supply_rejects_1h,
         COALESCE(rr.supply_rejects_24h, 0)::bigint AS supply_rejects_24h,
         COALESCE(rr.capacity_sheds_1h, 0)::bigint AS capacity_sheds_1h,
         COALESCE(rr.capacity_sheds_24h, 0)::bigint AS capacity_sheds_24h,
         COALESCE(rr.latency_sheds_1h, 0)::bigint AS latency_sheds_1h,
         COALESCE(rr.latency_sheds_24h, 0)::bigint AS latency_sheds_24h,
         COALESCE(rr.unavailable_sheds_1h, 0)::bigint AS unavailable_sheds_1h,
         COALESCE(rr.unavailable_sheds_24h, 0)::bigint AS unavailable_sheds_24h,
         COALESCE(rr.hardware_mismatches_1h, 0)::bigint AS hardware_mismatches_1h,
         COALESCE(rr.hardware_mismatches_24h, 0)::bigint AS hardware_mismatches_24h,
         COALESCE(tr.served_24h, 0)::bigint AS served_24h,
         tr.actual_ttft_p95_ms_1h,
         tr.actual_ttft_p95_ms_24h,
         rr.rejected_ttft_p95_ms_1h,
         rr.rejected_ttft_p95_ms_24h
    FROM model_keys mk
    LEFT JOIN rejection_rollup rr USING (model)
    LEFT JOIN route_rollup tr USING (model)
    LEFT JOIN model_registry mr ON mr.id = mk.model
   ORDER BY COALESCE(rr.supply_rejects_1h, 0) DESC,
            COALESCE(rr.hardware_mismatches_1h, 0) DESC,
            COALESCE(rr.supply_rejects_24h, 0) DESC,
            COALESCE(tr.served_24h, 0) DESC,
            mk.model
`;
