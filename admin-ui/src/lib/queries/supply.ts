import "server-only";
import { query } from "@/lib/db";
import {
  CAPACITY_SHED_REASONS,
  LATENCY_SHED_REASONS,
  SUPPLY_SHED_REASONS,
  TRACKED_SUPPLY_REASONS,
  summarizeSupplyPressure,
  type SupplyPressureModel,
  type SupplyPressureSummary,
} from "@/lib/supply-pressure";

interface RawSupplyPressureRow {
  model: string;
  display_name: string | null;
  min_ram_gb: number | null;
  unserved_1h: string;
  unserved_24h: string;
  capacity_sheds_1h: string;
  capacity_sheds_24h: string;
  latency_sheds_1h: string;
  latency_sheds_24h: string;
  unavailable_sheds_1h: string;
  unavailable_sheds_24h: string;
  hardware_mismatches_1h: string;
  hardware_mismatches_24h: string;
  served_24h: string;
  actual_ttft_p95_ms_1h: number | null;
  actual_ttft_p95_ms_24h: number | null;
  rejected_ttft_p95_ms_1h: number | null;
  rejected_ttft_p95_ms_24h: number | null;
}

export interface SupplyPressureOverview {
  models: SupplyPressureModel[];
  summary: SupplyPressureSummary;
}

const SUPPLY_PRESSURE_SQL = `
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
           )::bigint AS unserved_1h,
           count(*) FILTER (
             WHERE reason_code = ANY($3::text[])
           )::bigint AS unserved_24h,
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
  usage_rollup AS (
    SELECT model,
           count(*)::bigint AS served_24h
      FROM usage
     WHERE created_at >= now() - interval '24 hours'
       AND model <> ''
     GROUP BY model
  ),
  ttft_rollup AS (
    SELECT model,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY actual_ttft_ms) FILTER (
             WHERE created_at >= now() - interval '1 hour'
           ) AS actual_ttft_p95_ms_1h,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY actual_ttft_ms)
             AS actual_ttft_p95_ms_24h
      FROM inference_routes
     WHERE created_at >= now() - interval '24 hours'
       AND model <> ''
       AND actual_ttft_ms > 0
     GROUP BY model
  ),
  model_keys AS (
    SELECT model FROM rejection_rollup
    UNION
    SELECT model FROM usage_rollup
    UNION
    SELECT model FROM ttft_rollup
  )
  SELECT mk.model,
         mr.display_name,
         mr.min_ram_gb,
         COALESCE(rr.unserved_1h, 0)::bigint AS unserved_1h,
         COALESCE(rr.unserved_24h, 0)::bigint AS unserved_24h,
         COALESCE(rr.capacity_sheds_1h, 0)::bigint AS capacity_sheds_1h,
         COALESCE(rr.capacity_sheds_24h, 0)::bigint AS capacity_sheds_24h,
         COALESCE(rr.latency_sheds_1h, 0)::bigint AS latency_sheds_1h,
         COALESCE(rr.latency_sheds_24h, 0)::bigint AS latency_sheds_24h,
         COALESCE(rr.unavailable_sheds_1h, 0)::bigint AS unavailable_sheds_1h,
         COALESCE(rr.unavailable_sheds_24h, 0)::bigint AS unavailable_sheds_24h,
         COALESCE(rr.hardware_mismatches_1h, 0)::bigint AS hardware_mismatches_1h,
         COALESCE(rr.hardware_mismatches_24h, 0)::bigint AS hardware_mismatches_24h,
         COALESCE(ur.served_24h, 0)::bigint AS served_24h,
         tr.actual_ttft_p95_ms_1h,
         tr.actual_ttft_p95_ms_24h,
         rr.rejected_ttft_p95_ms_1h,
         rr.rejected_ttft_p95_ms_24h
    FROM model_keys mk
    LEFT JOIN rejection_rollup rr USING (model)
    LEFT JOIN usage_rollup ur USING (model)
    LEFT JOIN ttft_rollup tr USING (model)
    LEFT JOIN model_registry mr ON mr.id = mk.model
   ORDER BY COALESCE(rr.unserved_1h, 0) DESC,
            COALESCE(rr.hardware_mismatches_1h, 0) DESC,
            COALESCE(rr.unserved_24h, 0) DESC,
            COALESCE(ur.served_24h, 0) DESC,
            mk.model
`;

function numeric(value: string | number | null): number {
  return value === null ? 0 : Number(value);
}

function optionalNumeric(value: string | number | null): number | null {
  return value === null ? null : Number(value);
}

export async function getSupplyPressure(): Promise<SupplyPressureOverview> {
  const rows = await query<RawSupplyPressureRow>(SUPPLY_PRESSURE_SQL, [
    [...CAPACITY_SHED_REASONS],
    [...LATENCY_SHED_REASONS],
    [...SUPPLY_SHED_REASONS],
    [...TRACKED_SUPPLY_REASONS],
  ]);

  const models = rows.map<SupplyPressureModel>((row) => ({
    model: row.model,
    displayName: row.display_name || row.model,
    minRamGB: row.min_ram_gb,
    unserved1h: numeric(row.unserved_1h),
    unserved24h: numeric(row.unserved_24h),
    capacitySheds1h: numeric(row.capacity_sheds_1h),
    capacitySheds24h: numeric(row.capacity_sheds_24h),
    latencySheds1h: numeric(row.latency_sheds_1h),
    latencySheds24h: numeric(row.latency_sheds_24h),
    unavailableSheds1h: numeric(row.unavailable_sheds_1h),
    unavailableSheds24h: numeric(row.unavailable_sheds_24h),
    hardwareMismatches1h: numeric(row.hardware_mismatches_1h),
    hardwareMismatches24h: numeric(row.hardware_mismatches_24h),
    served24h: numeric(row.served_24h),
    actualTTFTP95Ms1h: optionalNumeric(row.actual_ttft_p95_ms_1h),
    actualTTFTP95Ms24h: optionalNumeric(row.actual_ttft_p95_ms_24h),
    rejectedTTFTP95Ms1h: optionalNumeric(row.rejected_ttft_p95_ms_1h),
    rejectedTTFTP95Ms24h: optionalNumeric(row.rejected_ttft_p95_ms_24h),
  }));

  return { models, summary: summarizeSupplyPressure(models) };
}
