import "server-only";
import { query } from "@/lib/db";
import { SUPPLY_PRESSURE_SQL } from "@/lib/queries/supply-sql";
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
  supply_rejects_1h: string;
  supply_rejects_24h: string;
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
    supplyRejects1h: numeric(row.supply_rejects_1h),
    supplyRejects24h: numeric(row.supply_rejects_24h),
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
